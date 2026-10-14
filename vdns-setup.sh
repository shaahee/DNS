#!/bin/bash
# VDNS - Debian 12 DNS: dnsdist answers every client (cache + Cloudflare/Google upstreams),
# BIND behind it answers the local zone, private reverse names and Apple content caching lookups.
# Includes the VDNS web dashboard and settings service.
# Run as root: bash vdns-setup.sh
# Unattended: VDNS_LISTEN=all (or =ip) skips the listen question.
# Safe to re-run: keeps the dashboard login and all settings made in the web interface.

set -u
cd /
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------- first-install defaults
# (after installation, change these on the dashboard's Settings page instead)
FORWARDERS='["1.1.1.1", "1.0.0.1"]'   # dnsdist upstreams: Cloudflare only
LAN="10.12.0.0/16"                 # allowed to open the dashboard
BIND_PORT="5300"                   # BIND listens on 127.0.0.1 only; dnsdist owns port 53
DASH_PORT="8443"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOGFILE="/var/log/hf-dns-setup-$STAMP.log"
BACKUP="/root/bind-backup-$STAMP"
APP="/opt/dnsdash"
ETCD="/etc/dnsdash"
DATA="/var/lib/dnsdash"

[ "$(id -u)" = "0" ] || { echo "Run as root: bash $0"; exit 1; }
exec > >(tee -a "$LOGFILE") 2>&1
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\n!! FAILED: %s\n!! Full log: %s\n' "$*" "$LOGFILE"; exit 1; }

# ----------------------------------------------------------------- preflight
step "Preflight"
. /etc/os-release
echo "OS: $PRETTY_NAME"
[ "${VERSION_ID:-}" = "12" ] || echo "WARN: written for Debian 12; continuing on $PRETTY_NAME"
IFACE="$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[ -n "$IP" ] || die "could not detect this server's IPv4 address"
ALL_IPS="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ' | sed 's/ $//')"
MODE="ip"
if [ -f "$ETCD/settings.json" ]; then
    PREV="$(python3 -c "import json;l=json.load(open('$ETCD/settings.json'))['resolver']['listen'];print(' '.join(l))" 2>/dev/null)"
    case " $PREV " in *" any "*) MODE="all" ;; esac
fi
echo "Detected interface $IFACE, address $IP (all addresses: $ALL_IPS)"
if [ -n "${VDNS_LISTEN:-${BLIND9_LISTEN:-}}" ]; then
    case "${VDNS_LISTEN:-${BLIND9_LISTEN:-}}" in all|any) MODE="all" ;; *) MODE="ip" ;; esac
else
    DEF=1; [ "$MODE" = "all" ] && DEF=2
    echo "Answer DNS and serve the dashboard on:"
    echo "  1) $IP on $IFACE only"
    echo "  2) All interfaces ($ALL_IPS, and any added later)"
    echo "  3) A different address"
    read -r -p "Choice [$DEF]: " ans < /dev/tty
    case "${ans:-$DEF}" in
        2|a|A|all) MODE="all" ;;
        3) MODE="ip"; read -r -p "IPv4 address to use: " IP < /dev/tty ;;
        *) MODE="ip" ;;
    esac
fi
ip -4 -o addr | grep -q " $IP/" || die "$IP is not configured on this server"
if [ "$MODE" = "all" ]; then
    LISTEN_JSON='["any"]'; DASH_BIND="0.0.0.0"
    echo "Using all interfaces. ns1.huvafen.internal and the tests use $IP."
else
    LISTEN_JSON="[\"127.0.0.1\", \"$IP\"]"; DASH_BIND="$IP"
    echo "Using $IP on $IFACE."
fi

for pid in $(ss -lnpuH 'sport = :53' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    comm="$(cat /proc/"$pid"/comm 2>/dev/null)"
    case "$comm" in named|dnsdist) continue ;; esac
    # all interfaces: anything on :53 conflicts except the systemd-resolved stub (127.0.0.53/54)
    if [ "$MODE" = "all" ]; then busy_re="(0\.0\.0\.0|\*|[0-9.]+):53"
    else busy_re="(0\.0\.0\.0|\*|${IP//./\\.}|127\.0\.0\.1):53"; fi
    ss -lnpuH 'sport = :53' | grep "pid=$pid," | grep -vE '127\.0\.0\.5[34]:53' | grep -qE "$busy_re" && \
        die "port 53 is held by $comm (PID $pid). Stop or disable it first."
done
if [ -f /etc/bind/named.conf ] && ! grep -qE "hf-debian-dns-setup|Managed by dnsdash-agent" /etc/bind/named.conf; then
    echo "An existing BIND configuration was found. Zones it defines:"
    grep -rhoE 'zone +"[^"]+"' /etc/bind/*.conf* 2>/dev/null | sort -u | sed 's/^/    /'
    read -r -p "It will be backed up to $BACKUP and replaced. Continue? [y/N] " ans < /dev/tty
    case "$ans" in y|Y) ;; *) die "cancelled" ;; esac
fi

# ----------------------------------------------------------------- packages + system tuning
step "Installing packages"
apt-get update -q || die "apt-get update failed"
apt-get install -y -q bind9 bind9-utils bind9-dnsutils python3 tcpdump openssl curl ca-certificates gnupg || die "apt install failed"
named -V | head -1

step "Installing dnsdist"
# Newest stable dnsdist from PowerDNS when reachable (faster, more features); Debian's own package otherwise.
CODENAME="${VERSION_CODENAME:-bookworm}"
if ! grep -qs "repo.powerdns.com" /etc/apt/sources.list.d/pdns-dnsdist.list; then
    for ch in 20 19; do
        if curl -fsS -m 10 -o /dev/null "https://repo.powerdns.com/debian/dists/$CODENAME-dnsdist-$ch/Release"; then
            install -d /etc/apt/keyrings
            if curl -fsS -m 20 -o /etc/apt/keyrings/powerdns-dnsdist.asc https://repo.powerdns.com/FD380FBB-pub.asc; then
                echo "deb [signed-by=/etc/apt/keyrings/powerdns-dnsdist.asc] https://repo.powerdns.com/debian $CODENAME-dnsdist-$ch main" \
                    > /etc/apt/sources.list.d/pdns-dnsdist.list
                printf 'Package: dnsdist*\nPin: origin repo.powerdns.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/dnsdist
                if apt-get update -q; then echo "Using PowerDNS dnsdist $ch repository"; else
                    echo "WARN: PowerDNS repository not usable; using Debian's dnsdist"
                    rm -f /etc/apt/sources.list.d/pdns-dnsdist.list /etc/apt/preferences.d/dnsdist; apt-get update -q
                fi
            fi
            break
        fi
    done
fi
# keep the package from starting with its sample config while BIND still holds port 53
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
apt-get install -y -q dnsdist; rc=$?
rm -f /usr/sbin/policy-rc.d
[ $rc -eq 0 ] || die "dnsdist install failed"
dnsdist --version | head -1

step "System tuning"
timedatectl set-ntp true 2>/dev/null || true
cat > /etc/sysctl.d/90-hf-dns.conf <<'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# low latency: poll the NIC briefly instead of sleeping until the next interrupt (costs a little idle CPU)
net.core.busy_read = 50
net.core.busy_poll = 50
net.ipv4.ip_local_port_range = 10240 65000
EOF
[ -e /proc/sys/net/netfilter/nf_conntrack_max ] && echo "net.netfilter.nf_conntrack_max = 262144" >> /etc/sysctl.d/90-hf-dns.conf
sysctl -q -p /etc/sysctl.d/90-hf-dns.conf || echo "WARN: some sysctl values were not applied"
# CPU at full clock (no frequency ramp-up delay) where the hypervisor exposes frequency scaling
if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1; then
    echo 'w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance' > /etc/tmpfiles.d/vdns-cpu.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/vdns-cpu.conf 2>/dev/null && echo "CPU governor: performance"
fi
mkdir -p /etc/systemd/system/named.service.d
printf '[Service]\nLimitNOFILE=65536\nRestart=always\nRestartSec=2\n' > /etc/systemd/system/named.service.d/hf-tuning.conf
mkdir -p /etc/systemd/system/dnsdist.service.d
rm -f /etc/systemd/system/dnsdist.service.d/blind9.conf
cat > /etc/systemd/system/dnsdist.service.d/vdns.conf <<'EOF'
[Unit]
After=named.service
Wants=named.service

[Service]
LimitNOFILE=1048576
LimitMEMLOCK=infinity
Restart=always
RestartSec=1
EOF
sed -i 's/^OPTIONS=.*/OPTIONS="-u bind -4"/' /etc/default/named
grep -q '^OPTIONS=' /etc/default/named || echo 'OPTIONS="-u bind -4"' >> /etc/default/named
systemctl daemon-reload

# ----------------------------------------------------------------- accounts, folders, files
step "Installing dashboard and settings service"
id dnsdash >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin dnsdash
systemctl stop dnsdash 2>/dev/null || true
mkdir -p "$APP/web" "$ETCD" "$DATA" /etc/bind/zones /var/log/named /var/log/dnsdash /var/lib/dnsdash-agent
chown root:root "$APP" "$APP/web"; chmod 755 "$APP" "$APP/web"
chown root:dnsdash "$ETCD"; chmod 750 "$ETCD"
chown dnsdash:dnsdash "$DATA"; chmod 700 "$DATA"
chown root:bind /etc/bind/zones; chmod 750 /etc/bind/zones
chown bind:bind /var/log/named; chmod 750 /var/log/named
chmod 750 /var/log/dnsdash /var/lib/dnsdash-agent

cat > "$APP/dnsdash.py" <<'DNSDASH_FILE_END'
#!/usr/bin/env python3
"""
dnsdash - DNS dashboard for the Huvafen Fushi BIND resolver.

Reads DNS traffic passively from the network interface (tcpdump, no BIND query
logging needed), stores 24 h of data in SQLite, serves an HTTPS dashboard with
login. Python 3 standard library only.

Starts as root (to run tcpdump), then drops to an unprivileged user.
"""
import base64
import collections
import grp
import hashlib
import hmac
import ipaddress
import json
import os
import pwd
import secrets
import socket
import sqlite3
import ssl
import struct
import subprocess
import sys
import threading
import time
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CFG_PATH = os.environ.get("DNSDASH_CONFIG", "/opt/local/etc/dnsdash/config.json")
with open(CFG_PATH) as fh:
    CFG = json.load(fh)

SERVER_IP = CFG["server_ip"]
RET = {"query": int(CFG.get("retention_hours", 24)) * 3600, "stats": 90 * 86400}   # refreshed from Settings every minute
DB_PATH = CFG["db"]
FAST_MS = float(CFG.get("fast_ms", 1.0))      # answered faster than this = cache/local
PENDING_TIMEOUT = 10.0
ALLOW = [ipaddress.ip_network(n, strict=False) for n in CFG.get("allow", ["10.0.0.0/8", "127.0.0.1/32"])]
SESSION_TTL = int(CFG.get("session_hours", 12)) * 3600
AGENT_SOCK = CFG.get("agent_socket", "/run/dnsdash/agent.sock")
RPZ_ZONES = {"rpz.block": "custom", "rpz.lists": "list"}
DD_SECRET = CFG.get("dnsdist_secret", "/etc/dnsdash/dnsdist.json")
# names dnsdist sends to BIND (kept in step with the agent's routing; refreshed from Settings every minute)
PRIVATE_SUFFIXES = ("10.in-addr.arpa", "168.192.in-addr.arpa", "254.169.in-addr.arpa",
                    *[f"{n}.172.in-addr.arpa" for n in range(16, 32)], "resolver.arpa", "home.arpa")
LOCAL = {"suffixes": ("huvafen.internal",) + PRIVATE_SUFFIXES, "apple": True}


def is_local(qn):
    if LOCAL["apple"] and (qn.startswith("_aaplcache._tcp.") or "._aaplcache._tcp." in qn):
        return True
    return any(qn == sfx or qn.endswith("." + sfx) for sfx in LOCAL["suffixes"])


class Dnsdist:
    """Read-only access to dnsdist's built-in web server (loopback, API key / password from the agent)."""

    def __init__(self):
        self.sec, self.loaded = None, 0

    def secret(self):
        if self.sec is None or time.time() - self.loaded > 60:
            try:
                with open(DD_SECRET) as f:
                    self.sec = json.load(f)
            except (OSError, ValueError):
                self.sec = None
            self.loaded = time.time()
        return self.sec

    def base(self):
        sec = self.secret()
        return ("http://" + sec.get("web", "127.0.0.1:8083")) if sec else None

    def _req(self, path, timeout=4):
        sec = self.secret()
        if not sec:
            raise OSError("dnsdist is not configured")
        auth = base64.b64encode(f"vdns:{sec['web_password']}".encode()).decode()
        req = urllib.request.Request(self.base() + path, headers={"X-API-Key": sec["api_key"], "Authorization": "Basic " + auth})
        return urllib.request.urlopen(req, timeout=timeout)

    def get(self, path):
        with self._req(path) as r:
            return json.load(r)

    def raw(self, path):
        try:
            with self._req(path, timeout=8) as r:
                return r.status, r.headers.get("Content-Type", "application/octet-stream"), r.read(8 * 1024 * 1024)
        except urllib.error.HTTPError as ex:
            return ex.code, "text/plain; charset=utf-8", b"dnsdist web server error"


DD = Dnsdist()


class DdSampler:
    """Samples dnsdist every 2 s so the live charts show the last 5 minutes as soon as a page opens."""

    def __init__(self):
        self.hist = collections.deque(maxlen=150)
        self.prev = None
        self.lock = threading.Lock()

    def run(self):
        while True:
            try:
                st = DD.get("/jsonstat?command=stats")
                now = time.time()
                cur = (now, st.get("queries", 0), st.get("frontend-servfail", 0), st.get("cache-hits", 0),
                       st.get("cache-misses", 0), st.get("cpu-user-msec", 0) + st.get("cpu-sys-msec", 0))
                p = self.prev
                self.prev = cur
                if p and cur[1] >= p[1] and now > p[0]:
                    dt = now - p[0]
                    dh, dm = cur[3] - p[3], cur[4] - p[4]
                    with self.lock:
                        self.hist.append({"t": round(now, 2), "qps": round((cur[1] - p[1]) / dt, 2),
                                          "fps": round(max(0, cur[2] - p[2]) / dt, 3),
                                          "hit": round(100.0 * dh / (dh + dm), 1) if dh + dm > 0 else None,
                                          "cpu": round(max(0.0, (cur[5] - p[5]) / (dt * 10)), 1)})
                elif p and cur[1] < p[1]:
                    with self.lock:
                        self.hist.clear()                 # dnsdist restarted
            except Exception:
                self.prev = None
            time.sleep(2)

    def points(self):
        with self.lock:
            return list(self.hist)


DDS = DdSampler()

QTYPES = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX", 16: "TXT", 28: "AAAA",
          33: "SRV", 35: "NAPTR", 43: "DS", 46: "RRSIG", 48: "DNSKEY", 64: "SVCB", 65: "HTTPS",
          255: "ANY", 257: "CAA"}
RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}


LAT_EDGES = [0.5, 1, 5, 20, 50, 100, 300]   # ms; 8 latency buckets


def detect_local_ips():
    ips = {"127.0.0.1", SERVER_IP}
    ips.update(CFG.get("server_ips", []))
    for cmd in (["ip", "-4", "-o", "addr"], ["/sbin/ifconfig"], ["ifconfig"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        toks = out.replace("/", " ").split()
        for i, tok in enumerate(toks[:-1]):
            if tok != "inet":
                continue
            try:
                a = ipaddress.ip_address(toks[i + 1])
            except ValueError:
                continue
            if a.version == 4:
                ips.add(str(a))
        if len(ips) > 2:
            break
    return ips


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------- database
SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS q (ts REAL, client TEXT, qname TEXT, qtype TEXT, rcode TEXT, ans INTEGER, lat REAL);
CREATE INDEX IF NOT EXISTS q_ts ON q(ts);
CREATE INDEX IF NOT EXISTS q_client_ts ON q(client, ts);
CREATE TABLE IF NOT EXISTS m (minute INTEGER PRIMARY KEY, n INTEGER, fast INTEGER, nx INTEGER, sf INTEGER,
    ref INTEGER, noresp INTEGER, lat_sum REAL, lat_n INTEGER, p50 REAL, p95 REAL);
CREATE TABLE IF NOT EXISTS cm (minute INTEGER, client TEXT, n INTEGER, nx INTEGER, sf INTEGER,
    lat_sum REAL, lat_n INTEGER, PRIMARY KEY(minute, client));
CREATE TABLE IF NOT EXISTS um (minute INTEGER, server TEXT, n INTEGER, lat_sum REAL, timeouts INTEGER,
    PRIMARY KEY(minute, server));
CREATE TABLE IF NOT EXISTS mh (minute INTEGER PRIMARY KEY, h0 INTEGER, h1 INTEGER, h2 INTEGER, h3 INTEGER,
    h4 INTEGER, h5 INTEGER, h6 INTEGER, h7 INTEGER);
CREATE TABLE IF NOT EXISTS ch (hour INTEGER, client TEXT, n INTEGER, nx INTEGER, sf INTEGER, blk INTEGER,
    lat_sum REAL, lat_n INTEGER, PRIMARY KEY(hour, client));
CREATE TABLE IF NOT EXISTS nh (hour INTEGER, kind TEXT, qname TEXT, n INTEGER, pol TEXT, PRIMARY KEY(hour, kind, qname));
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS bs (minute INTEGER PRIMARY KEY, hits INTEGER, misses INTEGER, queries INTEGER,
    cache_mem INTEGER);
"""


def db_rw():
    c = sqlite3.connect(DB_PATH, timeout=30, isolation_level=None)
    c.execute("PRAGMA synchronous=NORMAL")
    return c


def migrate(c):
    for sql in ("ALTER TABLE q ADD COLUMN pol TEXT", "ALTER TABLE m ADD COLUMN blk INTEGER DEFAULT 0",
                "ALTER TABLE cm ADD COLUMN blk INTEGER DEFAULT 0", "ALTER TABLE m ADD COLUMN loc INTEGER DEFAULT 0"):
        try:
            c.execute(sql)
        except sqlite3.OperationalError:
            pass          # column already exists
    c.execute("CREATE INDEX IF NOT EXISTS q_rcode_ts ON q(rcode, ts)")


def db_ro():
    c = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=30)
    c.execute("PRAGMA query_only=1")
    return c


# --------------------------------------------------------------------------- capture
def start_tcpdump():
    cmd = [CFG.get("tcpdump", "/usr/sbin/tcpdump"), "-i", CFG.get("iface", "en0"), "-n", "-U",
           "-s", "512", "-w", "-", CFG.get("bpf", "udp port 53")]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)


def readn(f, n):
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_name(d, i):
    labels, jumps, end = [], 0, None
    while True:
        ln = d[i]
        if ln == 0:
            i += 1
            break
        if ln & 0xC0 == 0xC0:
            if end is None:
                end = i + 2
            i = ((ln & 0x3F) << 8) | d[i + 1]
            jumps += 1
            if jumps > 40:
                raise IndexError("loop")
            continue
        labels.append(d[i + 1:i + 1 + ln].decode("ascii", "replace"))
        i += 1 + ln
    return ".".join(labels).lower(), (end if end is not None else i)


def policy_zone(d, i, count):
    """Walk `count` resource records from offset i; return the RPZ zone whose SOA BIND attached, if any."""
    for _ in range(count):
        name, i = read_name(d, i)
        typ, _, _, rdlen = struct.unpack("!HHIH", d[i:i + 10])
        i += 10 + rdlen
        if typ == 6 and name in RPZ_ZONES:
            return RPZ_ZONES[name]
    return None


def parse_dns(d):
    if len(d) < 12:
        return None
    did, fl, qd, an, ns, ar = struct.unpack("!HHHHHH", d[:12])
    qr, rcode = fl >> 15, fl & 0xF
    if qd < 1:
        return did, qr, rcode, an, ".", 0, None
    labels, i = [], 12
    try:
        while True:
            ln = d[i]
            if ln == 0:
                i += 1
                break
            if ln & 0xC0:
                i += 2
                break
            labels.append(d[i + 1:i + 1 + ln].decode("ascii", "replace"))
            i += 1 + ln
        qtype = struct.unpack("!H", d[i:i + 2])[0]
    except (IndexError, struct.error):
        return None
    pol = None
    if qr == 1 and an == 0 and rcode in (0, 3) and (ns or ar):
        try:
            pol = policy_zone(d, i + 4, ns + ar)
        except (IndexError, struct.error):
            pol = None                      # truncated capture: treat as a normal answer
    return did, qr, rcode, an, ".".join(labels).lower() or ".", qtype, pol


class Collector:
    def __init__(self, local_ips):
        self.local = frozenset(local_ips)
        self.lock = threading.Lock()
        self.rows = []            # finished client queries
        self.up = []              # (ts, server, lat_ms or None)
        self.pc = {}              # pending client queries
        self.pu = {}              # pending upstream queries

    def packet(self, ts, src, sport, dst, dport, dns):
        p = parse_dns(dns)
        if not p:
            return
        did, qr, rcode, an, qname, qtype, pol = p
        L = self.local
        with self.lock:
            if qr == 0 and dport == 53 and dst in L:
                # a client (possibly this host) asking us; duplicates from "-i any" are ignored
                self.pc.setdefault((src, sport, did), (ts, qname, qtype))
            elif qr == 1 and sport == 53 and src in L:
                # our answer: matched on client address + port + query id, whatever local IP sent it
                q = self.pc.pop((dst, dport, did), None)
                if q:
                    self.rows.append((q[0], dst, q[1], QTYPES.get(q[2], str(q[2])),
                                      "BLOCKED" if pol else RCODES.get(rcode, str(rcode)), an,
                                      max(0.0, (ts - q[0]) * 1000.0), pol))
            elif qr == 0 and dport == 53 and src in L:
                self.pu.setdefault((dst, sport, did), ts)          # our query to a forwarder
            elif qr == 1 and sport == 53 and dst in L:
                t0 = self.pu.pop((src, dport, did), None)          # forwarder's answer
                if t0 is not None:
                    self.up.append((t0, src, max(0.0, (ts - t0) * 1000.0)))

    def sweep(self):
        cut = time.time() - PENDING_TIMEOUT
        with self.lock:
            for k in [k for k, v in self.pc.items() if v[0] < cut]:
                ts, qn, qt = self.pc.pop(k)
                self.rows.append((ts, k[0], qn, QTYPES.get(qt, str(qt)), "NORESP", 0, None, None))
            for k in [k for k, v in self.pu.items() if v < cut]:
                self.up.append((self.pu.pop(k), k[0], None))

    def take(self):
        with self.lock:
            r, u = self.rows, self.up
            self.rows, self.up = [], []
        return r, u


def capture_loop(proc, col):
    f = proc.stdout
    try:
        gh = readn(f, 24)
        magic = gh[:4]
        if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
            e = "<"
        elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
            e = ">"
        else:
            log("unknown capture format", magic.hex())
            os._exit(1)
        nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
        div = 1e9 if nano else 1e6
        link = struct.unpack(e + "I", gh[20:24])[0]
        log(f"capture started, linktype {link}")
        while True:
            sec, frac, incl, _ = struct.unpack(e + "IIII", readn(f, 16))
            data = readn(f, incl)
            try:
                if link == 1:                       # Ethernet
                    off, et = 14, struct.unpack("!H", data[12:14])[0]
                    while et == 0x8100:             # VLAN tag
                        et = struct.unpack("!H", data[off + 2:off + 4])[0]
                        off += 4
                    if et != 0x0800:
                        continue
                elif link == 0:                     # BSD loopback
                    off = 4
                elif link == 113:                   # Linux cooked capture (SLL, "-i any")
                    if struct.unpack("!H", data[14:16])[0] != 0x0800:
                        continue
                    off = 16
                elif link == 276:                   # Linux cooked capture v2 (SLL2)
                    if struct.unpack("!H", data[0:2])[0] != 0x0800:
                        continue
                    off = 20
                elif link in (12, 14, 101):         # raw IP
                    off = 0
                else:
                    continue
                if data[off] >> 4 != 4 or data[off + 9] != 17:
                    continue
                if struct.unpack("!H", data[off + 6:off + 8])[0] & 0x1FFF:
                    continue                        # non-first fragment
                ihl = (data[off] & 0xF) * 4
                src = socket.inet_ntoa(data[off + 12:off + 16])
                dst = socket.inet_ntoa(data[off + 16:off + 20])
                u = off + ihl
                sport, dport = struct.unpack("!HH", data[u:u + 4])
                col.packet(sec + frac / div, src, sport, dst, dport, data[u + 8:])
            except (IndexError, struct.error):
                continue
    except EOFError:
        pass
    log("tcpdump stopped - exiting so launchd restarts the service")
    os._exit(1)


# --------------------------------------------------------------------------- writer
def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))]


class Writer:
    def __init__(self, col):
        self.col = col
        self.db = None
        self.mins = {}     # minute -> dict
        self.cms = {}      # (minute, client) -> [n, nx, sf, lat_sum, lat_n]
        self.ums = {}      # (minute, server) -> [n, lat_sum, timeouts]
        self.last_purge = 0
        self.last_ret = 0
        self.last_bind = None
        self.next_bind = 0

    def run(self):
        self.db = db_rw()                      # sqlite connections are per-thread
        while True:
            time.sleep(1)
            try:
                self.col.sweep()
                self.flush()
                now = time.time()
                if now >= self.next_bind:
                    self.next_bind = (int(now) // 60 + 1) * 60
                    self.poll_bind(now)
                if now - self.last_ret > 60:
                    self.refresh_retention()
                    self.last_ret = now
                if now - self.last_purge > 60:
                    self.rollup(now)
                    self.purge(now)
                    self.last_purge = now
            except Exception as ex:  # keep running
                log("writer error:", repr(ex))

    def flush(self):
        rows, ups = self.col.take()
        if not rows and not ups:
            return
        dm, dcm, dum = set(), set(), set()
        for ts, cl, qn, qt, rc, an, lat, pol in rows:
            mi = int(ts // 60)
            st = self.mins.setdefault(mi, {"n": 0, "fast": 0, "nx": 0, "sf": 0, "ref": 0, "noresp": 0, "lats": [],
                                           "h": [0] * 8, "blk": 0, "loc": 0})
            st["n"] += 1
            if is_local(qn):
                st["loc"] = st.get("loc", 0) + 1
            c = self.cms.setdefault((mi, cl), [0, 0, 0, 0.0, 0, 0])
            c[0] += 1
            if rc == "BLOCKED":
                st["blk"] += 1; c[5] += 1
            elif rc == "NXDOMAIN":
                st["nx"] += 1; c[1] += 1
            elif rc == "SERVFAIL":
                st["sf"] += 1; c[2] += 1
            elif rc == "REFUSED":
                st["ref"] += 1
            elif rc == "NORESP":
                st["noresp"] += 1
            if lat is not None:
                st["lats"].append(lat)
                st["h"][next((i for i, e in enumerate(LAT_EDGES) if lat < e), 7)] += 1
                c[3] += lat; c[4] += 1
                if lat < FAST_MS:
                    st["fast"] += 1
            dm.add(mi); dcm.add((mi, cl))
        for ts, sv, lat in ups:
            mi = int(ts // 60)
            u = self.ums.setdefault((mi, sv), [0, 0.0, 0])
            if lat is None:
                u[2] += 1
            else:
                u[0] += 1; u[1] += lat
            dum.add((mi, sv))
        db = self.db
        db.execute("BEGIN")
        db.executemany("INSERT INTO q (ts,client,qname,qtype,rcode,ans,lat,pol) VALUES (?,?,?,?,?,?,?,?)",
                       [(r[0], r[1], r[2], r[3], r[4], r[5], None if r[6] is None else round(r[6], 3), r[7]) for r in rows])
        for mi in dm:
            s = self.mins[mi]
            l = s["lats"]
            db.execute("INSERT OR REPLACE INTO m (minute,n,fast,nx,sf,ref,noresp,lat_sum,lat_n,p50,p95,blk,loc) "
                       "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (mi, s["n"], s["fast"], s["nx"], s["sf"], s["ref"], s["noresp"],
                        sum(l), len(l), pct(l, 50), pct(l, 95), s["blk"], s.get("loc", 0)))
            db.execute("INSERT OR REPLACE INTO mh VALUES (?,?,?,?,?,?,?,?,?)", (mi, *s["h"]))
        for k in dcm:
            c = self.cms[k]
            db.execute("INSERT OR REPLACE INTO cm (minute,client,n,nx,sf,lat_sum,lat_n,blk) VALUES (?,?,?,?,?,?,?,?)",
                       (k[0], k[1], *c))
        for k in dum:
            u = self.ums[k]
            db.execute("INSERT OR REPLACE INTO um VALUES (?,?,?,?,?)", (k[0], k[1], *u))
        db.execute("COMMIT")
        cut = int(time.time() // 60) - 3          # late answers arrive within 10 s
        for mi in [m for m in self.mins if m < cut]:
            del self.mins[mi]
        for k in [k for k in self.cms if k[0] < cut]:
            del self.cms[k]
        for k in [k for k in self.ums if k[0] < cut]:
            del self.ums[k]

    def poll_bind(self, now):
        try:
            d = DD.get("/api/v1/servers/localhost")
            st = d.get("statistics", {})
            cur = (st.get("cache-hits", 0), st.get("cache-misses", 0), st.get("queries", 0))
            mem = sum(p.get("cacheEntries", 0) for p in d.get("pools", []))
            prev, self.last_bind = self.last_bind, cur
            if prev is not None:
                delta = [c - p if c >= p else c for c, p in zip(cur, prev)]   # counter reset = dnsdist restart
                self.db.execute("INSERT OR REPLACE INTO bs VALUES (?,?,?,?,?)", (int(now // 60) - 1, *delta, mem))
            return
        except Exception:
            pass                                                  # no dnsdist: fall back to BIND's cache counters
        try:
            with urllib.request.urlopen(CFG.get("stats_url", "http://127.0.0.1:8053/json/v1/server"), timeout=5) as r:
                d = json.load(r)
        except Exception as ex:
            log("bind stats unavailable:", repr(ex))
            return
        cs = d.get("views", {}).get("_default", {}).get("resolver", {}).get("cachestats", {})
        cur = (cs.get("QueryHits", 0), cs.get("QueryMisses", 0), d.get("opcodes", {}).get("QUERY", 0))
        mem = sum(cs.get(k, 0) for k in ("TreeMemInUse", "HeapMemInUse"))
        prev, self.last_bind = self.last_bind, cur
        if prev is None:
            return
        delta = [c - p if c >= p else c for c, p in zip(cur, prev)]   # counter reset = BIND restart
        self.db.execute("INSERT OR REPLACE INTO bs VALUES (?,?,?,?,?)", (int(now // 60) - 1, *delta, mem))

    def refresh_retention(self):
        try:
            st = agent_call("get_settings", timeout=10)["settings"]
            d = st.get("data", {})
            r = st.get("resolver", {})
            LOCAL["suffixes"] = tuple([st.get("local", {}).get("zone", "huvafen.internal")] + list(PRIVATE_SUFFIXES) + list(r.get("local_suffixes", [])))
            LOCAL["apple"] = bool(r.get("apple_to_bind", True))
            RET["query"] = int(d.get("query_hours", 24)) * 3600
            RET["stats"] = int(d.get("stats_days", 90)) * 86400
        except Exception:
            pass                                    # keep the last known values

    def rollup(self, now):
        """Hourly summaries (per client, top names) that outlive individual queries."""
        if now % 3600 < 90:
            return
        target = int(now // 3600) - 1
        db = self.db
        row = db.execute("SELECT v FROM meta WHERE k='rolled_hour'").fetchone()
        last = int(row[0]) if row else target - min(48, RET["query"] // 3600)
        for h in range(last + 1, target + 1):
            a, b = h * 3600, h * 3600 + 3600
            db.execute("BEGIN")
            db.execute("INSERT OR REPLACE INTO ch SELECT ?, client, SUM(n), SUM(nx), SUM(sf), SUM(COALESCE(blk,0)), SUM(lat_sum), SUM(lat_n) "
                       "FROM cm WHERE minute >= ? AND minute < ? GROUP BY client", (h, h * 60, h * 60 + 60))
            for kind, cond, lim in (("all", "", 300), ("blk", "AND rcode='BLOCKED'", 300), ("nx", "AND rcode='NXDOMAIN'", 150)):
                db.execute(f"INSERT OR REPLACE INTO nh SELECT ?, ?, qname, COUNT(*), MAX(pol) FROM q WHERE ts >= ? AND ts < ? {cond} "
                           f"GROUP BY qname ORDER BY 4 DESC LIMIT {lim}", (h, kind, a, b))
            db.execute("INSERT OR REPLACE INTO meta VALUES ('rolled_hour', ?)", (str(h),))
            db.execute("COMMIT")

    def purge(self, now):
        qcut, scut = now - RET["query"], now - RET["stats"]
        db = self.db
        db.execute("BEGIN")
        db.execute("DELETE FROM q WHERE ts < ?", (qcut,))
        db.execute("DELETE FROM cm WHERE minute < ?", (int(qcut // 60),))
        for t in ("m", "mh", "um", "bs"):
            db.execute(f"DELETE FROM {t} WHERE minute < ?", (int(scut // 60),))
        for t in ("ch", "nh"):
            db.execute(f"DELETE FROM {t} WHERE hour < ?", (int(scut // 3600),))
        db.execute("COMMIT")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")


# --------------------------------------------------------------------------- queries
class Cache:
    def __init__(self):
        self.d, self.lock = {}, threading.Lock()

    def get(self, key, ttl, fn):
        now = time.time()
        with self.lock:
            v = self.d.get(key)
            if v and now - v[0] < ttl:
                return v[1]
        res = fn()
        with self.lock:
            self.d[key] = (now, res)
        return res


CACHE = Cache()


def window(qs):
    try:
        w = int(qs.get("w", ["3600"])[0])
    except ValueError:
        w = 3600
    return max(300, min(w, RET["stats"]))


def detail(w):
    """True when the window is fully covered by individual-query detail."""
    return w <= RET["query"]


def api_summary(w):
    now = time.time()
    sm = int((now - w) // 60)
    c = db_ro()
    try:
        n, fast, nx, sf, ref, nr, ls, ln, blk, loc = c.execute(
            "SELECT COALESCE(SUM(n),0),COALESCE(SUM(fast),0),COALESCE(SUM(nx),0),COALESCE(SUM(sf),0),"
            "COALESCE(SUM(ref),0),COALESCE(SUM(noresp),0),COALESCE(SUM(lat_sum),0),COALESCE(SUM(lat_n),0),"
            "COALESCE(SUM(blk),0),COALESCE(SUM(loc),0) FROM m WHERE minute>=?", (sm,)).fetchone()
        p95 = c.execute("SELECT SUM(p95*lat_n)/NULLIF(SUM(lat_n),0) FROM m WHERE minute>=? AND p95 IS NOT NULL",
                        (sm,)).fetchone()[0]
        p50 = c.execute("SELECT SUM(p50*lat_n)/NULLIF(SUM(lat_n),0) FROM m WHERE minute>=? AND p50 IS NOT NULL",
                        (sm,)).fetchone()[0]
        sh = int((now - w) // 3600)
        ctab, ccol, cval = ("cm", "minute", sm) if detail(w) else ("ch", "hour", sh)
        clients = c.execute(f"SELECT COUNT(DISTINCT client) FROM {ctab} WHERE {ccol}>=?", (cval,)).fetchone()[0]
        blk_clients = c.execute(f"SELECT COUNT(DISTINCT client) FROM {ctab} WHERE {ccol}>=? AND blk>0", (cval,)).fetchone()[0]
        h, mi = c.execute("SELECT COALESCE(SUM(hits),0),COALESCE(SUM(misses),0) FROM bs WHERE minute>=?",
                          (sm,)).fetchone()
        mem = c.execute("SELECT cache_mem FROM bs ORDER BY minute DESC LIMIT 1").fetchone()
        cur_min = int(now // 60) - 1
        last = c.execute("SELECT n FROM m WHERE minute=?", (cur_min,)).fetchone()
        up = [dict(server=r[0], n=r[1], avg=r[2], timeouts=r[3]) for r in c.execute(
            "SELECT server,SUM(n),SUM(lat_sum)/NULLIF(SUM(n),0),SUM(timeouts) FROM um WHERE minute>=? "
            "GROUP BY server ORDER BY SUM(n) DESC", (sm,))]
        oldest = c.execute("SELECT MIN(minute) FROM m").fetchone()[0]
        peak = c.execute("SELECT minute, n FROM m WHERE minute>=? ORDER BY n DESC LIMIT 1", (sm,)).fetchone()
        top_client = c.execute(f"SELECT client, SUM(n) FROM {ctab} WHERE {ccol}>=? GROUP BY client ORDER BY 2 DESC LIMIT 1",
                               (cval,)).fetchone()
    finally:
        c.close()
    return dict(window=w, queries=n, qps_avg=n / float(w), qps_last=(last[0] / 60.0) if last else 0,
                fast_pct=(100.0 * fast / ln) if ln else None, avg_ms=(ls / ln) if ln else None,
                p50_ms=p50, p95_ms=p95, nx_pct=(100.0 * nx / n) if n else None, nx=nx, sf=sf, local=loc,
                sf_pct=(100.0 * sf / n) if n else None, refused=ref, noresp=nr, clients=clients,
                hit_ratio=(100.0 * h / (h + mi)) if (h + mi) else None, cache_hits=h, cache_misses=mi,
                cache_mem=mem[0] if mem else None, upstream=up,
                data_since=(oldest * 60) if oldest else None, now=now,
                peak_qpm=peak[1] if peak else None, peak_at=(peak[0] * 60) if peak else None,
                top_client=top_client[0] if top_client else None, top_client_n=top_client[1] if top_client else None,
                blocked=blk, blocked_pct=(100.0 * blk / n) if n else None, blocked_clients=blk_clients,
                detail=detail(w), query_hours=RET["query"] // 3600, stats_days=RET["stats"] // 86400)


def api_live():
    now = time.time()
    c = db_ro()
    try:
        rows = c.execute("SELECT CAST(ts/10 AS INTEGER)*10 AS t, COUNT(*), AVG(lat), SUM(rcode='BLOCKED') FROM q "
                         "WHERE ts>=? GROUP BY t ORDER BY t", (now - 900,)).fetchall()
    finally:
        c.close()
    cur = int(now // 10) * 10 - 10          # last complete 10-second slot
    by = {r[0]: r for r in rows}
    last = by.get(cur)
    return dict(now=now, slot=10, points=[dict(t=r[0], qps=r[1] / 10.0, lat=r[2], bps=(r[3] or 0) / 10.0) for r in rows],
                qps_now=(last[1] / 10.0) if last else 0.0, lat_now=last[2] if last else None,
                bps_now=((last[3] or 0) / 10.0) if last else 0.0)


def api_latency(w):
    sm = int((time.time() - w) // 60)
    c = db_ro()
    try:
        r = c.execute("SELECT " + ",".join(f"COALESCE(SUM(h{i}),0)" for i in range(8)) + " FROM mh WHERE minute>=?",
                      (sm,)).fetchone()
        nr = c.execute("SELECT COALESCE(SUM(noresp),0) FROM m WHERE minute>=?", (sm,)).fetchone()[0]
    finally:
        c.close()
    return dict(edges=LAT_EDGES, counts=list(r), noresp=nr)


def api_series(w):
    sm = int((time.time() - w) // 60)
    b = max(1, w // 60 // 360)          # at most ~360 points
    c = db_ro()
    try:
        rows = c.execute(
            "SELECT (minute/?)*? AS t, SUM(n), SUM(lat_sum)/NULLIF(SUM(lat_n),0), MAX(p95), SUM(nx), SUM(sf), SUM(fast),"
            " SUM(lat_n), COALESCE(SUM(blk),0) FROM m WHERE minute>=? GROUP BY t ORDER BY t", (b, b, sm)).fetchall()
    finally:
        c.close()
    return dict(bucket_min=b, points=[dict(t=r[0] * 60, n=r[1], qpm=r[1] / float(b), avg=r[2], p95=r[3],
                                           nx=r[4], sf=r[5], fast=(100.0 * r[6] / r[7]) if r[7] else None,
                                           blk=r[8], bpm=r[8] / float(b))
                                      for r in rows])


def api_clients(w):
    now = time.time()
    tab, col, since, unit = ("cm", "minute", int((now - w) // 60), 60) if detail(w) else ("ch", "hour", int((now - w) // 3600), 3600)
    c = db_ro()
    try:
        rows = c.execute(
            f"SELECT client,SUM(n),SUM(nx),SUM(sf),SUM(lat_sum)/NULLIF(SUM(lat_n),0),MAX({col}),COALESCE(SUM(blk),0) FROM {tab} "
            f"WHERE {col}>=? GROUP BY client ORDER BY SUM(n) DESC LIMIT 1000", (since,)).fetchall()
    finally:
        c.close()
    return [dict(client=r[0], n=r[1], nx=r[2], sf=r[3], avg=r[4], last=r[5] * unit + unit - 1, blk=r[6]) for r in rows]


def api_top(w, client=None):
    if detail(w) or client:
        out = api_top_raw(min(w, RET["query"]), client)
        out["scope"] = "detail" if detail(w) else "detail-only"
        return out
    now = time.time()
    c = db_ro()
    try:
        row = c.execute("SELECT v FROM meta WHERE k='rolled_hour'").fetchone()
        rolled = int(row[0]) if row else int(now // 3600) - 1
        sh = int((now - w) // 3600)
        tail = (rolled + 1) * 3600

        def merged(kind, cond, lim):
            acc, pol = {}, {}
            for q, n, p in c.execute("SELECT qname, SUM(n), MAX(pol) FROM nh WHERE kind=? AND hour>=? AND hour<=? GROUP BY qname",
                                     (kind, sh, rolled)):
                acc[q] = acc.get(q, 0) + n; pol[q] = p
            for q, n, p in c.execute(f"SELECT qname, COUNT(*), MAX(pol) FROM q WHERE ts>=? {cond} GROUP BY qname", (tail,)):
                acc[q] = acc.get(q, 0) + n; pol[q] = pol.get(q) or p
            top = sorted(acc.items(), key=lambda x: -x[1])[:lim]
            return [[q, n, pol.get(q)] for q, n in top]
        names = [r[:2] for r in merged("all", "", 15)]
        nxn = [r[:2] for r in merged("nx", "AND rcode='NXDOMAIN'", 10)]
        blocked = merged("blk", "AND rcode='BLOCKED'", 15)
        sm = int((now - w) // 60)
        n, nx, sf, ref, nr, blk = c.execute("SELECT COALESCE(SUM(n),0),COALESCE(SUM(nx),0),COALESCE(SUM(sf),0),COALESCE(SUM(ref),0),"
                                            "COALESCE(SUM(noresp),0),COALESCE(SUM(blk),0) FROM m WHERE minute>=?", (sm,)).fetchone()
        rcodes = [[k, v] for k, v in (("NOERROR", max(0, n - nx - sf - ref - nr - blk)), ("BLOCKED", blk), ("NXDOMAIN", nx),
                                      ("SERVFAIL", sf), ("NORESP", nr), ("REFUSED", ref)) if v]
        bclients = c.execute("SELECT client, SUM(blk) FROM ch WHERE hour>=? AND blk>0 GROUP BY client ORDER BY 2 DESC LIMIT 10",
                             (sh,)).fetchall()
        types = c.execute("SELECT qtype,COUNT(*) FROM q WHERE ts>=? GROUP BY qtype ORDER BY 2 DESC LIMIT 8",
                          (now - RET["query"],)).fetchall()
    finally:
        c.close()
    return dict(names=names, nxdomain=nxn, types=types, rcodes=rcodes, blocked=blocked, blocked_clients=bclients, scope="summary")


def api_top_raw(w, client=None):
    since = time.time() - w
    c = db_ro()
    try:
        where, args = "ts>=?", [since]
        if client:
            where += " AND client=?"
            args.append(client)
        names = c.execute(f"SELECT qname,COUNT(*) FROM q WHERE {where} GROUP BY qname ORDER BY 2 DESC LIMIT 15",
                          args).fetchall()
        nxn = c.execute(f"SELECT qname,COUNT(*) FROM q WHERE {where} AND rcode='NXDOMAIN' GROUP BY qname "
                        "ORDER BY 2 DESC LIMIT 10", args).fetchall()
        types = c.execute(f"SELECT qtype,COUNT(*) FROM q WHERE {where} GROUP BY qtype ORDER BY 2 DESC LIMIT 8",
                          args).fetchall()
        rcodes = c.execute(f"SELECT rcode,COUNT(*) FROM q WHERE {where} GROUP BY rcode ORDER BY 2 DESC",
                           args).fetchall()
        blocked = c.execute(f"SELECT qname,COUNT(*),MAX(pol) FROM q WHERE {where} AND rcode='BLOCKED' GROUP BY qname "
                            "ORDER BY 2 DESC LIMIT 15", args).fetchall()
        bclients = c.execute(f"SELECT client,COUNT(*) FROM q WHERE {where} AND rcode='BLOCKED' GROUP BY client "
                             "ORDER BY 2 DESC LIMIT 10", args).fetchall()
    finally:
        c.close()
    return dict(names=names, nxdomain=nxn, types=types, rcodes=rcodes,
                blocked=[[r[0], r[1], r[2]] for r in blocked], blocked_clients=bclients)


def api_log(qs):
    w = window(qs)
    lim = max(1, min(int((qs.get("limit", ["300"])[0] or "300")), 2000))
    where, args = ["ts>=?"], [time.time() - min(w, RET["query"])]
    cl = (qs.get("client", [""])[0] or "").strip()
    nm = (qs.get("q", [""])[0] or "").strip().lower()
    rc = (qs.get("rcode", [""])[0] or "").strip().upper()
    slow = qs.get("slow", [""])[0]
    if cl:
        where.append("client=?"); args.append(cl)
    if nm:
        where.append("qname LIKE ? ESCAPE '\\'")
        args.append("%" + nm.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%")
    if rc in ("NOERROR", "NXDOMAIN", "SERVFAIL", "REFUSED", "NORESP", "FORMERR", "BLOCKED"):
        where.append("rcode=?"); args.append(rc)
    if slow:
        where.append("lat>=?"); args.append(float(CFG.get("slow_ms", 50)))
    args.append(lim)
    c = db_ro()
    try:
        rows = c.execute(f"SELECT ts,client,qname,qtype,rcode,ans,lat,pol FROM q WHERE {' AND '.join(where)} "
                         "ORDER BY ts DESC LIMIT ?", args).fetchall()
    finally:
        c.close()
    return [dict(ts=r[0], client=r[1], qname=r[2], qtype=r[3], rcode=r[4], ans=r[5], lat=r[6], pol=r[7]) for r in rows]


# --------------------------------------------------------------------------- content caching
ACC_DB = CFG.get("acc_db", os.path.join(os.path.dirname(DB_PATH), "acc.db"))


def acc_ro():
    if not os.path.exists(ACC_DB):
        return None
    c = sqlite3.connect(f"file:{ACC_DB}?mode=ro", uri=True, timeout=30)
    c.execute("PRAGMA query_only=1")
    return c


def acc_days(qs):
    try:
        d = int(qs.get("d", ["7"])[0])
    except ValueError:
        d = 7
    return max(1, min(d, 366))


def acc_summary(d):
    c = acc_ro()
    if c is None:
        return dict(available=False)
    try:
        since = time.time() - d * 86400
        st = c.execute("SELECT ts,activated,active,cache_status,cache_used,actual_used,cache_limit,cache_free,"
                       "pressure,details,peers,parents,public_ip FROM status ORDER BY ts DESC LIMIT 1").fetchone()
        sm = c.execute("SELECT COALESCE(SUM(cache_to_client),0),COALESCE(SUM(origin_to_client),0),"
                       "COALESCE(SUM(peer_to_client),0),COALESCE(SUM(cache_to_peer),0),COALESCE(SUM(origin_to_peer),0),"
                       "SUM(req_clients),SUM(rep_cache_client),SUM(rep_origin_client),COALESCE(SUM(dropped),0),"
                       "COUNT(*) FROM metrics WHERE ts>=?", (since,)).fetchone()
        first = c.execute("SELECT MIN(ts) FROM metrics").fetchone()[0]
        src = c.execute("SELECT v FROM meta WHERE k='source'").fetchone()
    finally:
        c.close()
    cache, origin, peer = sm[0], sm[1], sm[2]
    served = cache + origin + peer
    out = dict(available=True, days=d, served=served, from_cache=cache, from_origin=origin, from_peers=peer,
               to_peers=sm[3] + sm[4], requests=sm[5], replies_cache=sm[6], replies_origin=sm[7], dropped=sm[8],
               samples=sm[9], efficiency=(100.0 * (cache + peer) / served) if served else None,
               history_since=first, source=src[0] if src else None, now=time.time())
    if st:
        try:
            det = json.loads(st[9] or "{}")
        except ValueError:
            det = {}
        out.update(status_ts=st[0], activated=bool(st[1]), active=bool(st[2]), cache_status=st[3],
                   cache_used=st[4], actual_used=st[5], cache_limit=st[6], cache_free=st[7], pressure=st[8],
                   details=sorted(([k, v] for k, v in det.items() if v), key=lambda x: -x[1]),
                   peers=st[10], parents=st[11], public_ip=st[12])
    return out


def acc_series(d):
    c = acc_ro()
    if c is None:
        return dict(available=False, points=[], size=[])
    b = 3600 if d <= 7 else 86400
    off = time.localtime().tm_gmtoff
    since = time.time() - d * 86400
    try:
        pts = c.execute(f"SELECT CAST((ts+?)/? AS INTEGER)*?-? AS t, COALESCE(SUM(cache_to_client),0),"
                        f" COALESCE(SUM(origin_to_client),0), COALESCE(SUM(peer_to_client),0), SUM(req_clients)"
                        f" FROM metrics WHERE ts>=? GROUP BY t ORDER BY t", (off, b, b, off, since)).fetchall()
        size = c.execute(f"SELECT CAST((ts+?)/? AS INTEGER)*?-? AS t, AVG(cache_used), MAX(cache_limit)"
                         f" FROM status WHERE ts>=? GROUP BY t ORDER BY t", (off, b, b, off, since)).fetchall()
    finally:
        c.close()
    return dict(available=True, bucket=b, offset=off,
                points=[dict(t=r[0], cache=r[1], origin=r[2], peer=r[3], req=r[4]) for r in pts],
                size=[dict(t=r[0], used=r[1], limit=r[2]) for r in size])


# --------------------------------------------------------------------------- host stats
class Host:
    def __init__(self):
        self.lock = threading.Lock()
        self.cpu = None
        self.prev = None
        self.named_pid = None
        self.pids = {}

    @staticmethod
    def _cpu_times():
        with open("/proc/stat") as f:
            v = [int(x) for x in f.readline().split()[1:]]
        idle = v[3] + (v[4] if len(v) > 4 else 0)
        return sum(v), idle

    def run(self):
        while True:
            try:
                tot, idle = self._cpu_times()
                if self.prev:
                    dt, di = tot - self.prev[0], idle - self.prev[1]
                    with self.lock:
                        self.cpu = max(0.0, min(100.0, 100.0 * (dt - di) / dt)) if dt else 0.0
                self.prev = (tot, idle)
            except (OSError, ValueError, IndexError):
                pass
            time.sleep(3)

    def rss(self, comm):
        known = self.pids.get(comm)
        pids = [known] if known else [p for p in os.listdir("/proc") if p.isdigit()]
        for p in pids:
            try:
                with open(f"/proc/{p}/comm") as f:
                    if f.read().strip() != comm:
                        continue
                with open(f"/proc/{p}/status") as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            self.pids[comm] = p
                            return int(line.split()[1]) * 1024
            except OSError:
                continue
        self.pids.pop(comm, None)
        return None if not known else self.rss(comm)

    def named_rss(self):
        return self.rss("named")

    def snapshot(self):
        mem = {}
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    k, v = line.split(":", 1)
                    mem[k] = int(v.split()[0]) * 1024
        except OSError:
            pass
        total, avail = mem.get("MemTotal"), mem.get("MemAvailable")
        disk = {}
        for label, path in (("root", "/"), ("data", os.path.dirname(DB_PATH))):
            try:
                st = os.statvfs(path)
                disk[label] = {"free": st.f_bavail * st.f_frsize, "total": st.f_blocks * st.f_frsize}
            except OSError:
                pass
        try:
            load = os.getloadavg()
        except OSError:
            load = None
        try:
            with open("/proc/uptime") as f:
                up = float(f.read().split()[0])
        except OSError:
            up = None
        with self.lock:
            cpu = self.cpu
        return dict(cpu=cpu, mem_pct=(100.0 * (total - avail) / total) if total and avail is not None else None,
                    mem_total=total, mem_used=(total - avail) if total and avail is not None else None,
                    disk=disk, load=load, uptime=up, cores=os.cpu_count(), named_rss=self.named_rss(), dnsdist_rss=self.rss("dnsdist"), now=time.time())


HOST = Host()

DD_STATS = ("queries", "responses", "cache-hits", "cache-misses", "frontend-noerror", "frontend-nxdomain", "frontend-servfail",
            "servfail-responses", "downstream-timeouts", "downstream-send-errors", "acl-drops", "rule-drop", "rule-truncated",
            "self-answered", "no-policy", "udp-recvbuf-errors", "udp-sndbuf-errors", "udp-in-errors", "tcp-listen-overflows",
            "latency0-1", "latency1-10", "latency10-50", "latency50-100", "latency100-1000", "latency-slow",
            "latency-avg100", "latency-avg1000", "latency-avg10000", "latency-tcp-avg1000", "real-memory-usage",
            "cpu-user-msec", "cpu-sys-msec", "uptime", "fd-usage", "over-capacity-drops", "too-old-drops")


BIND_NS = ("QryAuthAns", "QryNoauthAns", "QrySuccess", "QryNXDOMAIN", "QryNxrrset", "QrySERVFAIL", "QryRecursion", "QryFailure",
           "QryUDP", "QryTCP", "QryDropped", "Requestv4", "Response", "QryDuplicate")


def api_bind():
    try:
        with urllib.request.urlopen(CFG.get("stats_url", "http://127.0.0.1:8053/json/v1/server"), timeout=4) as r:
            d = json.load(r)
    except Exception as ex:
        return {"ok": False, "error": f"BIND statistics are not available ({ex.__class__.__name__})"}
    ns = d.get("nsstats", {})
    res = d.get("views", {}).get("_default", {}).get("resolver", {})
    cs, rs = res.get("cachestats", {}), res.get("stats", {})
    rc = {k: v for k, v in d.get("rcodes", {}).items() if v}
    return {"ok": True, "version": d.get("version"), "boot": d.get("boot-time"), "config": d.get("config-time"),
            "now": d.get("current-time"), "queries": d.get("opcodes", {}).get("QUERY", 0),
            "ns": {k: ns.get(k, 0) for k in BIND_NS}, "rcodes": rc,
            "qtypes": sorted(d.get("qtypes", {}).items(), key=lambda kv: -kv[1])[:8],
            "forwarded": rs.get("Queryv4", 0) + rs.get("Queryv6", 0), "fwd_timeouts": rs.get("QueryTimeout", 0),
            "cache_nodes": cs.get("CacheNodes"), "cache_mem": cs.get("TreeMemInUse", 0) + cs.get("HeapMemInUse", 0),
            "rss": HOST.named_rss()}


# ---- client details: what the capture saw, plus what the server knows about the address
DEVICE_HINTS = [
    ("Apple device", ("apple.com", "icloud.com", "mzstatic.com", "aaplimg.com", "apple-dns.net", "cdn-apple.com", "itunes.apple.com", "_aaplcache")),
    ("Android device", ("android.googleapis.com", "connectivitycheck.gstatic.com", "play.googleapis.com", "android.clients.google.com", "mtalk.google.com")),
    ("Samsung device", ("samsungcloudsolution", "samsung.com", "samsungapps", "samsungqbe", "samsungosp")),
    ("Windows PC", ("msftconnecttest.com", "msftncsi.com", "windowsupdate.com", "login.live.com", "wns.windows.com")),
    ("Smart TV / streaming", ("netflix", "roku.com", "tizen", "lgtvsdp", "googlecast", "amazonvideo", "primevideo")),
    ("Lutron controls", ("lutron.com",)),
    ("Game console", ("playstation", "xboxlive", "nintendo")),
]
PTR_CACHE = {}


def ptr_lookup(ip):
    hit = PTR_CACHE.get(ip)
    if hit and time.time() - hit[1] < 600:
        return hit[0]
    name = None
    try:
        qid = secrets.randbits(16)
        q = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
        for label in ip.split(".")[::-1] + ["in-addr", "arpa"]:
            q += bytes([len(label)]) + label.encode()
        q += b"\x00" + struct.pack("!HH", 12, 1)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as so:
            so.settimeout(1.0)
            so.sendto(q, ("127.0.0.1", 53))
            d = so.recv(4096)
        rid, fl, qd, an = struct.unpack("!HHHH", d[:8])
        if rid == qid and fl & 0xF == 0 and an:
            i = 12
            for _ in range(qd):
                _, i = read_name(d, i)
                i += 4
            for _ in range(an):
                _, i = read_name(d, i)
                typ, _, _, rdlen = struct.unpack("!HHIH", d[i:i + 10])
                i += 10
                if typ == 12:
                    name = read_name(d, i)[0]
                    break
                i += rdlen
    except (OSError, ValueError, IndexError, struct.error):
        pass
    PTR_CACHE[ip] = (name, time.time())
    return name


def arp_entry(ip):
    try:
        with open("/proc/net/arp") as f:
            next(f)
            for line in f:
                p = line.split()
                if len(p) >= 6 and p[0] == ip and p[3] != "00:00:00:00:00:00":
                    first = int(p[3].split(":")[0], 16)
                    return {"mac": p[3], "dev": p[5], "private": bool(first & 0x02)}
    except (OSError, ValueError, StopIteration):
        pass
    return None


def api_client(ip, w):
    now = time.time()
    since = now - min(w, RET["query"])
    c = db_ro()
    try:
        n, nx, sf, first, last, lat = c.execute(
            "SELECT COUNT(*), COALESCE(SUM(rcode='NXDOMAIN'),0), COALESCE(SUM(rcode IN ('SERVFAIL','NORESP')),0), MIN(ts), MAX(ts), AVG(lat) "
            "FROM q WHERE client=? AND ts>=?", (ip, since)).fetchone()
        names = c.execute("SELECT qname, COUNT(*) FROM q WHERE client=? AND ts>=? GROUP BY qname ORDER BY 2 DESC LIMIT 12",
                          (ip, since)).fetchall()
        types = c.execute("SELECT qtype, COUNT(*) FROM q WHERE client=? AND ts>=? GROUP BY qtype ORDER BY 2 DESC LIMIT 6",
                          (ip, since)).fetchall()
        span = max(1.0, now - since)
        acts = [0] * 24
        for b, k in c.execute("SELECT CAST((ts - ?) * 24 / ? AS INTEGER), COUNT(*) FROM q WHERE client=? AND ts>=? GROUP BY 1",
                              (since, span, ip, since)):
            if 0 <= b < 24:
                acts[b] = k
        seen = c.execute("SELECT MIN(ts) FROM q WHERE client=?", (ip,)).fetchone()[0]
        h0 = c.execute("SELECT MIN(hour) FROM ch WHERE client=?", (ip,)).fetchone()[0]
        if h0 is not None:
            seen = min(seen or 1e18, h0 * 3600)
        hint_names = c.execute("SELECT qname, COUNT(*) FROM q WHERE client=? AND ts>=? GROUP BY qname ORDER BY 2 DESC LIMIT 400",
                               (ip, since)).fetchall()
    finally:
        c.close()
    score = collections.Counter()
    for qn, k in hint_names:
        for label, pats in DEVICE_HINTS:
            if any(pt in qn for pt in pats):
                score[label] += k
    hints = [[k, v] for k, v in score.most_common(3)]
    return {"client": ip, "queries": n, "nx": nx, "failed": sf, "first": first, "last": last, "avg": lat,
            "first_seen": seen, "names": names, "types": types, "activity": acts, "span": span,
            "hostname": ptr_lookup(ip), "arp": arp_entry(ip), "hints": hints, "nat": ip in NAT_HINT}


NAT_HINT = set(CFG.get("nat_clients", []))


DD_POLICY = {"v": None, "t": 0}


def dd_policy():
    """Server selection policy is only in jsonstat (a string); it changes only on restart, so ask once a minute."""
    if time.time() - DD_POLICY["t"] > 60:
        try:
            DD_POLICY["v"] = DD.get("/jsonstat?command=stats").get("server-policy")
        except Exception:
            pass
        DD_POLICY["t"] = time.time()
    return DD_POLICY["v"]


def api_dnsdist():
    try:
        d = DD.get("/api/v1/servers/localhost")
    except Exception as ex:
        return {"ok": False, "error": f"dnsdist is not answering on its web port ({ex.__class__.__name__})"}
    st = d.get("statistics", {})
    servers = [{k: sv.get(k) for k in ("name", "address", "state", "qps", "latency", "queries", "responses", "outstanding",
                                         "dropRate", "sendErrors", "order", "weight", "pools", "tcpLatency", "reuseds")}
               for sv in d.get("servers", [])]
    pools = [{k: pl.get(k) for k in ("name", "serversCount", "cacheSize", "cacheEntries", "cacheHits", "cacheMisses",
                                       "cacheTTLTooShorts", "cacheDeferredInserts", "cacheDeferredLookups")}
             for pl in d.get("pools", [])]
    rules = [{"rule": r.get("rule"), "action": r.get("action"), "matches": r.get("matches", 0)} for r in d.get("rules", [])]
    fronts = [{k: f.get(k) for k in ("address", "type", "queries", "responses", "udp", "tcp")} for f in d.get("frontends", [])]
    return {"ok": True, "version": d.get("version"), "stats": {k: st.get(k) for k in DD_STATS if k in st},
            "server_policy": st.get("server-policy") or dd_policy(), "servers": servers, "pools": pools, "rules": rules,
            "frontends": fronts, "acl": d.get("acl"), "now": time.time(), "hist": DDS.points()}


def db_info():
    size = sum(os.path.getsize(DB_PATH + ext) for ext in ("", "-wal") if os.path.exists(DB_PATH + ext))
    c = db_ro()
    try:
        qn, q0 = c.execute("SELECT COUNT(*), MIN(ts) FROM q").fetchone()
        m0 = c.execute("SELECT MIN(minute) FROM m").fetchone()[0]
    finally:
        c.close()
    return dict(db_bytes=size, queries=qn, oldest_query=q0, oldest_stats=(m0 * 60) if m0 else None,
                query_hours=RET["query"] // 3600, stats_days=RET["stats"] // 86400)


def db_maintenance(op):
    c = sqlite3.connect(DB_PATH, timeout=120, isolation_level=None)
    try:
        if op == "clear":
            c.execute("BEGIN")
            c.execute("DELETE FROM q")
            c.execute("DELETE FROM cm")
            c.execute("COMMIT")
        elif op == "reset":                     # everything: queries, per-minute statistics and hourly summaries
            c.execute("BEGIN")
            for t in ("q", "cm", "m", "mh", "um", "ch", "nh", "bs"):
                c.execute(f"DELETE FROM {t}")
            c.execute("DELETE FROM meta WHERE k='rolled_hour'")
            c.execute("COMMIT")
        c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        c.execute("VACUUM")
    finally:
        c.close()


# --------------------------------------------------------------------------- privileged agent
class AgentError(Exception):
    pass


def agent_call(cmd, args=None, actor=None, timeout=900):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(AGENT_SOCK)
        s.sendall((json.dumps({"cmd": cmd, "args": args or {}, "actor": actor or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError as ex:
        raise AgentError(f"The settings service is not reachable ({ex.strerror or ex}). Check: systemctl status dnsdash-agent")
    finally:
        s.close()
    try:
        res = json.loads(buf)
    except ValueError:
        raise AgentError("The settings service returned an unreadable reply")
    if not res.get("ok"):
        raise AgentError(res.get("error", "Unknown error"))
    return res["result"]


# --------------------------------------------------------------------------- auth
SESSIONS, SESS_LOCK = {}, threading.Lock()
FAILS = collections.defaultdict(collections.deque)


def check_password(user, pw):
    try:
        with open(CFG_PATH) as fh:          # re-read so password changes apply without a restart
            c = json.load(fh)
    except (OSError, ValueError):
        c = CFG
    exp = bytes.fromhex(c["hash"])
    got = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(c["salt"]), int(c["iterations"]))
    return hmac.compare_digest(user.encode(), c["user"].encode()) & hmac.compare_digest(got, exp)


def locked_out(ip):
    dq, now = FAILS[ip], time.time()
    while dq and now - dq[0] > 900:
        dq.popleft()
    return len(dq) >= 5


# --------------------------------------------------------------------------- http
HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = {}
for _name, _type in (("index.html", "text/html; charset=utf-8"), ("login.html", "text/html; charset=utf-8"),
                     ("app.js", "text/javascript; charset=utf-8"), ("app.css", "text/css; charset=utf-8"),
                     ("favicon.svg", "image/svg+xml")):
    with open(os.path.join(HERE, "web", _name), "rb") as _fh:
        STATIC[_name] = (_fh.read(), _type)

SEC_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                               "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
    "Strict-Transport-Security": "max-age=31536000",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "dnsdash"
    sys_version = ""
    timeout = 30
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(self.timeout)
        self.request.do_handshake()            # TLS handshake in the worker thread, not the accept loop
        super().setup()

    def log_message(self, fmt, *args):
        pass

    def ip(self):
        return self.client_address[0]

    def allowed(self):
        try:
            a = ipaddress.ip_address(self.ip())
        except ValueError:
            return False
        return any(a in n for n in ALLOW)

    def send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        for k, v in SEC_HEADERS.items():
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def dnsdist_ui(self, u):
        """dnsdist's own console, proxied so it opens inside VDNS without exposing its port or password."""
        sub = u.path[len("/dnsdist/ui"):] or "/"
        if sub == "/" and not u.path.endswith("/"):
            return self.send(301, "", extra={"Location": "/dnsdist/ui/"})
        if not re.match(r"^/[A-Za-z0-9._/-]*$", sub) or ".." in sub:
            return self.send(404, "Not found")
        if not re.match(r"^[A-Za-z0-9=&._-]*$", u.query):
            return self.send(400, "Bad request")
        code, ctype, body = DD.raw(sub + ("?" + u.query if u.query else ""))
        self.send_response(code)
        for k, v in SEC_HEADERS.items():
            if k not in ("Content-Security-Policy", "X-Frame-Options"):
                self.send_header(k, v)
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                         "frame-ancestors 'self'; base-uri 'none'; form-action 'none'")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, obj):
        self.send(200, json.dumps(obj, separators=(",", ":")), "application/json")

    def session(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "dd_session" and v:
                with SESS_LOCK:
                    s = SESSIONS.get(v)
                    if s and s["exp"] > time.time():
                        return v
                    SESSIONS.pop(v, None)
        return None

    def do_GET(self):
        if not self.allowed():
            return self.send(403, "Forbidden")
        u = urlparse(self.path)
        p, qs = u.path, parse_qs(u.query)
        if p == "/login":
            e = qs.get("e", [""])[0]
            msg = {"1": "Wrong username or password.",
                   "locked": "Too many failed attempts. Try again in 15 minutes."}.get(e, "")
            page = STATIC["login.html"][0].replace(b"{{MSG}}", msg.encode())
            return self.send(200, page, STATIC["login.html"][1])
        if p in ("/app.css",):
            return self.send(200, *STATIC["app.css"])
        if p in ("/favicon.svg", "/favicon.ico"):
            return self.send(200, *STATIC["favicon.svg"])
        if not self.session():
            if p.startswith("/api/"):
                return self.send(401, "login required")
            return self.send(303, "", extra={"Location": "/login"})
        if p == "/":
            return self.send(200, *STATIC["index.html"])
        if p == "/app.js":
            return self.send(200, *STATIC["app.js"])
        try:
            if p == "/api/summary":
                w = window(qs)
                return self.json(CACHE.get(("s", w), 5, lambda: api_summary(w)))
            if p == "/api/session":
                ses = SESSIONS.get(self.session())
                return self.json({"user": ses["user"], "csrf": ses["csrf"], "host": CFG.get("listen")})
            if p == "/api/settings":
                return self.json(agent_call("get_settings", actor=self.actor()))
            if p == "/api/status":
                return self.json(agent_call("status", actor=self.actor(), timeout=30))
            if p == "/api/audit":
                return self.json(agent_call("audit", actor=self.actor(), timeout=30))
            if p == "/api/bind":
                return self.json(CACHE.get(("bind",), 3, api_bind))
            if p == "/api/client":
                w = window(qs)
                ip = str(ipaddress.ip_address((qs.get("ip", [""])[0] or "").strip()))
                return self.json(CACHE.get(("cl", ip, w), 10, lambda: api_client(ip, w)))
            if p == "/api/dnsdist":
                return self.json(CACHE.get(("dd",), 1.5, api_dnsdist))
            if p == "/dnsdist/ui" or p.startswith("/dnsdist/ui/"):
                return self.dnsdist_ui(u)
            if p == "/api/host":
                return self.json(CACHE.get(("host",), 2, HOST.snapshot))
            if p == "/api/data":
                return self.json(CACHE.get(("data",), 10, db_info))
            if p == "/api/live":
                return self.json(CACHE.get(("live",), 4, api_live))
            if p == "/api/latency":
                w = window(qs)
                return self.json(CACHE.get(("lh", w), 15, lambda: api_latency(w)))
            if p == "/api/series":
                w = window(qs)
                return self.json(CACHE.get(("t", w), 15, lambda: api_series(w)))
            if p == "/api/clients":
                w = window(qs)
                return self.json(CACHE.get(("c", w), 15, lambda: api_clients(w)))
            if p == "/api/top":
                w = window(qs)
                cl = (qs.get("client", [""])[0] or "").strip()
                if cl:
                    ipaddress.ip_address(cl)
                ttl = 30 if w <= 3600 else 120
                return self.json(CACHE.get(("p", w, cl), ttl, lambda: api_top(w, cl or None)))
            if p == "/api/log":
                return self.json(api_log(qs))
            if p == "/api/acc/summary":
                d = acc_days(qs)
                return self.json(CACHE.get(("as", d), 30, lambda: acc_summary(d)))
            if p == "/api/acc/series":
                d = acc_days(qs)
                return self.json(CACHE.get(("at", d), 60, lambda: acc_series(d)))
        except AgentError as ex:
            return self.send(502, json.dumps({"error": str(ex)}), "application/json")
        except ValueError:
            return self.send(400, "bad request")
        except sqlite3.Error as ex:
            log("db error:", repr(ex))
            return self.send(503, "database busy")
        return self.send(404, "Not found")

    def do_HEAD(self):
        return self.do_GET()

    def do_POST(self):
        if not self.allowed():
            return self.send(403, "Forbidden")
        p = urlparse(self.path).path
        ln = int(self.headers.get("Content-Length", "0") or 0)
        if ln > 4 * 1024 * 1024 or (ln > 4096 and not p.startswith("/api/")):
            return self.send(413, "too large")
        body = self.rfile.read(ln).decode("utf-8", "replace")
        if p.startswith("/api/"):
            return self.api_post(p, body)
        if p == "/logout":
            tok = self.session()
            if tok:
                with SESS_LOCK:
                    SESSIONS.pop(tok, None)
            return self.send(303, "", extra={"Location": "/login",
                                             "Set-Cookie": "dd_session=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Strict"})
        if p == "/login":
            ip = self.ip()
            if locked_out(ip):
                log("login locked out:", ip)
                return self.send(303, "", extra={"Location": "/login?e=locked"})
            f = parse_qs(body)
            user, pw = f.get("user", [""])[0], f.get("password", [""])[0]
            if check_password(user, pw):
                FAILS.pop(ip, None)
                tok = secrets.token_urlsafe(32)
                with SESS_LOCK:
                    now = time.time()
                    for k in [k for k, v in SESSIONS.items() if v["exp"] < now]:
                        del SESSIONS[k]
                    SESSIONS[tok] = {"exp": now + SESSION_TTL, "csrf": secrets.token_urlsafe(24), "user": user}
                log("login ok:", ip)
                return self.send(303, "", extra={
                    "Location": "/",
                    "Set-Cookie": f"dd_session={tok}; Max-Age={SESSION_TTL}; Path=/; Secure; HttpOnly; SameSite=Strict"})
            FAILS[ip].append(time.time())
            log("login failed:", ip)
            time.sleep(1)
            return self.send(303, "", extra={"Location": "/login?e=1"})
        return self.send(404, "Not found")


def _api_post(self, p, body):
    tok = self.session()
    if not tok:
        return self.send(401, json.dumps({"error": "Your session has expired. Sign in again."}), "application/json")
    ses = SESSIONS.get(tok)
    if not hmac.compare_digest(self.headers.get("X-CSRF", ""), ses["csrf"]) or \
            not self.headers.get("Content-Type", "").startswith("application/json"):
        return self.send(403, json.dumps({"error": "Request rejected (security token missing). Reload the page."}), "application/json")
    try:
        data = json.loads(body or "{}")
        if not isinstance(data, dict):
            raise ValueError
    except ValueError:
        return self.send(400, json.dumps({"error": "Malformed request"}), "application/json")
    actor = self.actor()
    if p in ("/api/data/compact", "/api/data/clear", "/api/data/reset"):
        op = p.rsplit("/", 1)[1]
        try:
            db_maintenance(op)
        except sqlite3.Error as ex:
            return self.send(503, json.dumps({"error": f"Database busy, try again ({ex})"}), "application/json")
        log(f"database {op} by {actor['user']} from {actor['ip']}")
        CACHE.d.clear()
        return self.json({"message": {"clear": "Query history deleted and space reclaimed",
                                      "reset": "All history and statistics deleted. Counting starts again now."}.get(op, "Database compacted")})
    try:
        if p == "/api/settings":
            res = agent_call("apply_settings", {"settings": data.get("settings") or {}}, actor)
        elif p == "/api/service":
            res = agent_call("service", {"action": data.get("action"), "name": data.get("name", "")}, actor)
        elif p == "/api/rule":
            res = agent_call("quick_rule", {"domain": data.get("domain", ""), "op": data.get("op")}, actor, timeout=120)
        elif p == "/api/lists/update":
            res = agent_call("lists_update", {"only": data.get("only")}, actor, timeout=30)
        elif p == "/api/account":
            res = agent_call("set_password", {k: data.get(k, "") for k in ("user", "current", "password")}, actor, timeout=30)
        else:
            return self.send(404, json.dumps({"error": "Not found"}), "application/json")
    except AgentError as ex:
        return self.send(400, json.dumps({"error": str(ex)}), "application/json")
    CACHE.d.clear()
    return self.json({"message": res})


def _actor(self):
    ses = SESSIONS.get(self.session() or "", {})
    return {"user": ses.get("user", "?"), "ip": self.ip()}


Handler.api_post = _api_post
Handler.actor = _actor


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def handle_error(self, request, client_address):
        ex = sys.exc_info()[1]
        if not isinstance(ex, (ssl.SSLError, ConnectionError, socket.timeout, OSError)):
            log("http error from", client_address[0], repr(ex))


# --------------------------------------------------------------------------- main
def drop_privileges(user):
    pw = pwd.getpwnam(user)
    os.setgroups([])
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)
    if os.getuid() == 0:
        raise SystemExit("privilege drop failed")


def main():
    run_as = CFG.get("run_as")
    local_ips = detect_local_ips()
    proc = start_tcpdump()                     # needs root (or CAP_NET_RAW)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CFG["cert"], CFG["key"])
    srv = Server((CFG.get("listen", SERVER_IP), int(CFG.get("port", 8443))), Handler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)

    if run_as and os.getuid() == 0:
        drop_privileges(run_as)
    log(f"running as uid {os.getuid()}, https://{CFG.get('listen', SERVER_IP)}:{CFG.get('port', 8443)}")

    c = db_rw()
    c.executescript(SCHEMA)
    migrate(c)
    c.close()

    col = Collector(local_ips)
    log("local addresses:", ", ".join(sorted(local_ips)), "| capture:", CFG.get("iface", "en0"), CFG.get("bpf", "udp port 53"))
    threading.Thread(target=capture_loop, args=(proc, col), daemon=True).start()
    threading.Thread(target=Writer(col).run, daemon=True).start()
    threading.Thread(target=HOST.run, daemon=True).start()
    threading.Thread(target=DDS.run, daemon=True).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
DNSDASH_FILE_END
cat > "$APP/agent.py" <<'DNSDASH_FILE_END'
#!/usr/bin/env python3
"""
dnsdash-agent - the only privileged part of the DNS dashboard.

Runs as root, listens on a Unix socket that only the dashboard user (and root) may use,
and performs a fixed set of validated operations:

  get_settings / apply_settings      resolver options, local records, blocking
  quick_rule                         block / allow / remove a single domain
  service                            reload/restart BIND, restart dnsdist, flush caches, flush one name
  status                             dnsdist + BIND state, rndc status, recent log
  lists_update                       download blocklists and rebuild the policy zone
  set_password                       change the dashboard login
  audit                              recent change history

Every configuration change is written, checked with named-checkconf, and rolled back if BIND
rejects it. Python 3 standard library only.
"""
import base64
import copy
import datetime
import grp
import hashlib
import ipaddress
import json
import os
import pwd
import re
import secrets
import shutil
import socket
import socketserver
import struct
import subprocess
import tempfile
import sys
import threading
import time
import urllib.request

PATHS = {
    "settings": "/etc/dnsdash/settings.json",
    "dash_config": "/etc/dnsdash/config.json",
    "named_conf": "/etc/bind/named.conf",
    "zones": "/etc/bind/zones",
    "rndc_key": "/etc/bind/rndc.key",
    "log_dir": "/var/log/named",
    "cache_dir": "/var/cache/bind",
    "state": "/var/lib/dnsdash-agent",
    "socket": "/run/dnsdash/agent.sock",
    "audit": "/var/log/dnsdash/audit.log",
    "named_service": "named",
    "rndc": "rndc",
    "checkconf": "named-checkconf",
    "checkzone": "named-checkzone",
    "socket_group": "dnsdash",
    "client_user": "dnsdash",
    "systemctl": "systemctl",
    "dnsdist_conf": "/etc/dnsdist/dnsdist.conf",
    "dnsdist_secret": "/etc/dnsdash/dnsdist.json",
    "dnsdist": "dnsdist",
    "dnsdist_service": "dnsdist",
    "dnsdist_group": "_dnsdist",
    "bind_port": 5300,
}
if os.environ.get("AGENT_PATHS"):
    with open(os.environ["AGENT_PATHS"]) as _f:
        PATHS.update(json.load(_f))

RPZ_ALLOW, RPZ_BLOCK, RPZ_LISTS = "rpz.allow", "rpz.block", "rpz.lists"
LOCK = threading.RLock()
JOB = {"running": False, "started": None, "finished": None, "message": "", "ok": None}

DEFAULT_LISTS = [
    {"id": "hagezi-light", "name": "HaGeZi Light", "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt", "enabled": False, "wildcard": True},
    {"id": "hagezi-multi", "name": "HaGeZi Multi Normal", "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi-onlydomains.txt", "enabled": False, "wildcard": True},
    {"id": "hagezi-pro", "name": "HaGeZi Pro", "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt", "enabled": False, "wildcard": True},
    {"id": "stevenblack", "name": "StevenBlack Unified hosts", "url": "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", "enabled": False, "wildcard": False},
    {"id": "oisd-small", "name": "OISD Small", "url": "https://small.oisd.nl/domainswild2", "enabled": False, "wildcard": True},
    {"id": "hagezi-tif", "name": "HaGeZi Threat Intelligence", "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt", "enabled": False, "wildcard": True},
]

DEFAULT_SETTINGS = {
    "version": 1,
    "resolver": {                    # dnsdist front end (clients) + where it sends queries
        "listen": ["127.0.0.1"],
        "forwarders": ["1.1.1.1", "1.0.0.1"],
        "policy": "leastOutstanding",
        "query_acl": ["any"],
        "cache_entries": 1000000,
        "max_cache_ttl": 86400,
        "max_ncache_ttl": 3600,
        "serve_stale": True,
        "apple_to_bind": True,
        "local_suffixes": [],
        "rate_limit": {"enabled": False, "qps": 300, "exempt": ["127.0.0.1/32"]},
    },
    "local": {
        "zone": "huvafen.internal",
        "records": [
            {"name": "ns1", "type": "A", "value": "10.12.252.3", "ttl": None},
            {"name": "_aaplcache._tcp", "type": "TXT", "value": "prs=123.176.25.78,123.176.25.118", "ttl": 10800},
        ],
    },
    "blocking": {
        "enabled": False,
        "action": "nxdomain",
        "lists": DEFAULT_LISTS,
        "block": [],
        "allow": [],
        "auto_update_hours": 24,
    },
    "data": {
        "query_hours": 24,          # individual queries kept by the dashboard
        "stats_days": 90,           # per-minute statistics and hourly summaries
        "audit_days": 365,          # Settings > Activity history
        "bind_log_versions": 5,
        "bind_log_size_mb": 5,
    },
}
POLICIES = {"leastOutstanding": "fewest outstanding queries", "firstAvailable": "first healthy in list order",
            "roundrobin": "round robin", "wrandom": "weighted random"}
# Private and special-use names BIND answers itself; dnsdist sends these (and the local zone) to BIND.
LOCAL_SUFFIXES = ["10.in-addr.arpa", "168.192.in-addr.arpa", "254.169.in-addr.arpa",
                  *[f"{n}.172.in-addr.arpa" for n in range(16, 32)], "resolver.arpa", "home.arpa"]
QUERY_HOURS = (6, 12, 24, 72, 168, 336, 720)
STATS_DAYS = (7, 30, 90, 180, 365)
AUDIT_DAYS = (30, 90, 180, 365, 730)


class Bad(Exception):
    """A validation error shown to the user."""


# ----------------------------------------------------------------------------- helpers
def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), "agent:", *a, file=sys.stderr, flush=True)


def run(cmd, timeout=120):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except OSError as ex:
        return 127, str(ex)


def write_atomic(path, text, mode=0o640, group="bind"):
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    try:
        os.chown(tmp, 0, grp.getgrnam(group).gr_gid)
    except (KeyError, PermissionError):
        pass
    os.replace(tmp, path)


def audit(actor, action, detail=""):
    os.makedirs(os.path.dirname(PATHS["audit"]), exist_ok=True)
    line = json.dumps({"ts": time.time(), "user": actor.get("user", "?"), "ip": actor.get("ip", "?"),
                       "action": action, "detail": str(detail)[:500]})
    with open(PATHS["audit"], "a") as f:
        f.write(line + "\n")


DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?!-)([a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\.)*[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?$")


def norm_domain(s):
    d = str(s).strip().lower().rstrip(".")
    if d.startswith("*."):
        d = d[2:]
    if not d or not DOMAIN_RE.match(d) or "." not in d:
        return None
    try:
        ipaddress.ip_address(d)
        return None
    except ValueError:
        return d


def v_ip(s, what):
    try:
        a = ipaddress.ip_address(str(s).strip())
    except ValueError:
        raise Bad(f"{what}: '{s}' is not an IP address")
    if a.version != 4:
        raise Bad(f"{what}: only IPv4 is enabled on this resolver")
    return str(a)


def v_acl(s, what):
    s = str(s).strip()
    if s in ("any", "none", "localhost", "localnets"):
        return s
    try:
        return str(ipaddress.ip_network(s, strict=False))
    except ValueError:
        raise Bad(f"{what}: '{s}' is not an address or network (e.g. 10.12.0.0/16)")


def v_int(v, what, lo, hi):
    try:
        n = int(v)
    except (TypeError, ValueError):
        raise Bad(f"{what} must be a whole number")
    if not lo <= n <= hi:
        raise Bad(f"{what} must be between {lo} and {hi}")
    return n


def host_ips():
    code, out = run(["ip", "-4", "-o", "addr"], 10)
    ips = {"127.0.0.1"}
    toks = out.replace("/", " ").split()
    for i, t in enumerate(toks[:-1]):
        if t == "inet":
            ips.add(toks[i + 1])
    return ips


# ----------------------------------------------------------------------------- settings
def load_settings():
    try:
        with open(PATHS["settings"]) as f:
            s = json.load(f)
    except FileNotFoundError:
        s = {}
    out = copy.deepcopy(DEFAULT_SETTINGS)
    for k in ("resolver", "local", "blocking", "data"):
        if isinstance(s.get(k), dict):
            out[k].update(s[k])
    rl = out["resolver"].get("rate_limit", {})
    if "qps" not in rl:                 # old BIND response-rate-limit settings do not carry over
        rl = {"enabled": False, "qps": 300, "exempt": rl.get("exempt", ["127.0.0.1/32"])}
    out["resolver"]["rate_limit"] = {**DEFAULT_SETTINGS["resolver"]["rate_limit"], **rl}
    if out["resolver"].get("forwarders") in (["1.1.1.1", "1.0.0.1", "8.8.8.8"], ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]):
        out["resolver"]["forwarders"] = list(DEFAULT_SETTINGS["resolver"]["forwarders"])     # earlier defaults -> Cloudflare only
    out["blocking"]["enabled"] = False  # blocking is not used with dnsdist in front
    for l in out["blocking"].get("lists", []):          # HaGeZi moved its domain lists; old links return 404
        m = re.match(r"^https://raw\.githubusercontent\.com/hagezi/dns-blocklists/main/domains/(light|multi|pro|tif)\.txt$", l.get("url", ""))
        if m:
            l["url"] = f"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/{m.group(1)}-onlydomains.txt"
            l["wildcard"] = True
    return out


def save_settings(s):
    write_atomic(PATHS["settings"], json.dumps(s, indent=2), 0o600, "root")


def validate(s):
    """Return a cleaned copy of user-supplied settings or raise Bad."""
    cur = load_settings()
    r_in, r = s.get("resolver", {}), {}
    raw = [str(x).strip().lower() for x in r_in.get("listen", cur["resolver"]["listen"]) if str(x).strip()]
    if any(x in ("any", "all", "0.0.0.0", "*") for x in raw):
        # every IPv4 address on the server, including ones added later (BIND rescans interfaces)
        r["listen"] = ["any"]
    else:
        listen = [v_ip(x, "Listen address") for x in raw]
        mine = host_ips()
        for a in listen:
            if a not in mine:
                raise Bad(f"Listen address {a} is not configured on this server")
        if "127.0.0.1" not in listen:
            listen.insert(0, "127.0.0.1")
        r["listen"] = listen
    fw = []
    for x in r_in.get("forwarders", []):
        if str(x).strip():
            a = v_ip(x, "Upstream")
            if a not in fw:
                fw.append(a)
    if not 1 <= len(fw) <= 8:
        raise Bad("Add between 1 and 8 upstream servers")
    r["forwarders"] = fw
    r["policy"] = r_in.get("policy", "leastOutstanding")
    if r["policy"] not in POLICIES:
        raise Bad("Unknown upstream selection policy")
    acl = [v_acl(x, "Allowed clients") for x in r_in.get("query_acl", ["any"]) if str(x).strip()]
    if not acl:
        raise Bad("Allowed clients cannot be empty (use 'any' or your networks)")
    if any(a in ("none", "localnets") for a in acl):
        raise Bad("Allowed clients: use 'any', 'localhost' or networks such as 10.12.0.0/16")
    r["query_acl"] = acl
    r["cache_entries"] = v_int(r_in.get("cache_entries", 1000000), "Cache size (answers)", 10000, 20000000)
    r["max_cache_ttl"] = v_int(r_in.get("max_cache_ttl", 86400), "Maximum cache time", 60, 604800)
    r["max_ncache_ttl"] = v_int(r_in.get("max_ncache_ttl", 3600), "Maximum negative cache time", 0, 86400)
    r["serve_stale"] = bool(r_in.get("serve_stale", True))
    r["apple_to_bind"] = bool(r_in.get("apple_to_bind", True))
    sfx = []
    for x in r_in.get("local_suffixes", []):
        if str(x).strip():
            d = norm_domain(x)
            if not d:
                raise Bad(f"Domains for BIND: '{x}' is not a valid domain")
            if d not in sfx:
                sfx.append(d)
    if len(sfx) > 200:
        raise Bad("Domains for BIND: too many entries (max 200)")
    r["local_suffixes"] = sfx
    rl_in = r_in.get("rate_limit", {})
    r["rate_limit"] = {
        "enabled": bool(rl_in.get("enabled", False)),
        "qps": v_int(rl_in.get("qps", 300), "Queries per second per client", 10, 100000),
        "exempt": [v_acl(x, "Rate-limit exemptions") for x in rl_in.get("exempt", []) if str(x).strip()],
    }
    if any(a in ("any", "none", "localhost", "localnets") for a in r["rate_limit"]["exempt"]):
        raise Bad("Rate-limit exemptions: enter networks such as 10.12.110.2/32")

    l_in, recs = s.get("local", {}), []
    zone = norm_domain(l_in.get("zone", cur["local"]["zone"]))
    if not zone:
        raise Bad("Local zone name is not valid")
    seen = set()
    for i, rec in enumerate(l_in.get("records", [])):
        name = str(rec.get("name", "")).strip().lower().rstrip(".")
        if name in ("", "@"):
            name = "@"
        elif name.endswith("." + zone):
            name = name[: -len(zone) - 1]
        if name != "@" and not re.match(r"^[a-z0-9_*]([a-z0-9_.-]{0,200}[a-z0-9_])?$", name):
            raise Bad(f"Record {i + 1}: '{name}' is not a valid name")
        typ = str(rec.get("type", "A")).upper()
        val = str(rec.get("value", "")).strip()
        if typ == "A":
            val = v_ip(val, f"Record {name}")
        elif typ == "AAAA":
            try:
                val = str(ipaddress.IPv6Address(val))
            except ValueError:
                raise Bad(f"Record {name}: '{val}' is not an IPv6 address")
        elif typ == "CNAME":
            t = norm_domain(val) if "." in val else None
            if not t:
                raise Bad(f"Record {name}: CNAME target must be a full name like host.example.com")
            val = t + "."
        elif typ == "TXT":
            if not val or len(val) > 255 or '"' in val or "\\" in val or any(ord(c) < 32 for c in val):
                raise Bad(f"Record {name}: TXT must be 1-255 printable characters without quotes")
        else:
            raise Bad(f"Record {name}: type must be A, AAAA, CNAME or TXT")
        ttl = rec.get("ttl")
        ttl = None if ttl in (None, "", 0) else v_int(ttl, f"Record {name} TTL", 60, 604800)
        key = (name, typ, val)
        if key in seen:
            continue
        seen.add(key)
        recs.append({"name": name, "type": typ, "value": val, "ttl": ttl})
    if len(recs) > 5000:
        raise Bad("Too many local records (max 5000)")

    b_in, b = s.get("blocking", {}), {}
    b["enabled"] = False                 # blocking is not used with dnsdist in front
    b["action"] = b_in.get("action", "nxdomain")
    if b["action"] not in ("nxdomain", "nodata"):
        raise Bad("Block action must be 'nxdomain' or 'nodata'")
    b["auto_update_hours"] = v_int(b_in.get("auto_update_hours", 24), "Update interval (hours)", 0, 720)
    lists, ids = [], set()
    for i, l in enumerate(b_in.get("lists", [])):
        url = str(l.get("url", "")).strip()
        if not re.match(r"^https?://[A-Za-z0-9.-]+(:\d+)?/[^\s\"'<>]*$", url) or len(url) > 600:
            raise Bad(f"List {i + 1}: enter a full http(s) URL")
        lid = re.sub(r"[^a-z0-9-]", "-", str(l.get("id") or l.get("name") or f"list{i}").lower())[:40].strip("-") or f"list{i}"
        while lid in ids:
            lid += "-x"
        ids.add(lid)
        name = str(l.get("name", lid)).strip()[:80] or lid
        lists.append({"id": lid, "name": name, "url": url, "enabled": bool(l.get("enabled")), "wildcard": bool(l.get("wildcard", True))})
    if len(lists) > 40:
        raise Bad("Too many lists (max 40)")
    b["lists"] = lists
    for k, label in (("block", "Blocked domains"), ("allow", "Allowed domains")):
        out = []
        for x in b_in.get(k, []):
            d = norm_domain(x)
            if not d:
                raise Bad(f"{label}: '{x}' is not a valid domain")
            if d not in out:
                out.append(d)
        if len(out) > 50000:
            raise Bad(f"{label}: too many entries (max 50,000)")
        b[k] = out
    d_in, d = s.get("data", cur["data"]), {}
    for key, allowed, label in (("query_hours", QUERY_HOURS, "Query detail retention"),
                                ("stats_days", STATS_DAYS, "Statistics retention"),
                                ("audit_days", AUDIT_DAYS, "Activity retention")):
        v = v_int(d_in.get(key, DEFAULT_SETTINGS["data"][key]), label, 1, 100000)
        if v not in allowed:
            raise Bad(f"{label}: choose one of {', '.join(map(str, allowed))}")
        d[key] = v
    if d["query_hours"] > d["stats_days"] * 24:
        raise Bad("Query detail cannot be kept longer than the statistics")
    d["bind_log_versions"] = v_int(d_in.get("bind_log_versions", 5), "BIND log files to keep", 1, 30)
    d["bind_log_size_mb"] = v_int(d_in.get("bind_log_size_mb", 5), "BIND log file size (MB)", 1, 200)
    return {"version": 1, "resolver": r, "local": {"zone": zone, "records": recs}, "blocking": b, "data": d}


# ----------------------------------------------------------------------------- rendering
def next_serial():
    path = os.path.join(PATHS["state"], "serial")
    base = int(datetime.date.today().strftime("%Y%m%d")) * 100
    try:
        last = int(open(path).read().strip())
    except (OSError, ValueError):
        last = 0
    s = max(base, last + 1)
    os.makedirs(PATHS["state"], exist_ok=True)
    with open(path, "w") as f:
        f.write(str(s))
    return s


def soa(serial, zone, neg=300):
    return (f"$TTL 259200\n@ IN SOA ns1.{zone}. admin.{zone}. ( {serial} 3600 900 604800 {neg} )\n"
            f"@ IN NS ns1.{zone}.\n")


def rndc_keyname():
    try:
        for line in open(PATHS["rndc_key"]):
            m = re.match(r'\s*key\s+"?([^"\s]+)"?', line)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "rndc-key"


def render_named_conf(s):
    """BIND behind dnsdist: answers the local zone, private reverse zones and Apple content-caching lookups.
    Listens on loopback only; dnsdist is the only client. Anything outside its own zones (rare: _aaplcache
    under a foreign domain) is forwarded to the same upstreams dnsdist uses."""
    r, z = s["resolver"], PATHS["zones"]
    port = int(PATHS["bind_port"])
    lines = [
        "// Managed by dnsdash-agent. Edit through the dashboard's Settings page;",
        "// manual changes here are overwritten on the next save.",
        f'include "{PATHS["rndc_key"]}";',
        "",
        "options {",
        f'    directory              "{PATHS["cache_dir"]}";',
        f'    statistics-file        "{PATHS["cache_dir"]}/named.stats";',
        f'    dump-file              "{PATHS["cache_dir"]}/named_dump.db";',
        f'    recursing-file         "{PATHS["cache_dir"]}/named.recursing";',
        f'    managed-keys-directory "{PATHS["cache_dir"]}";',
        f"    listen-on port {port} {{ 127.0.0.1; }};",
        "    listen-on-v6 { none; };",
        "    recursion yes;",
        "    allow-query       { localhost; };",
        "    allow-recursion   { localhost; };",
        "    allow-query-cache { localhost; };",
        "    allow-transfer    { none; };",
        "    notify no;",
        f'    forwarders {{ {" ".join(f + ";" for f in r["forwarders"])} }};',
        "    forward only;",
        "    dnssec-validation auto;",
        "    version none;",
        "    hostname none;",
        "    server-id none;",
        "    minimal-responses yes;",
        "    minimal-any yes;",
        "    answer-cookie no;          // dnsdist caches answers for many clients; a server cookie would mismatch",
        "    max-cache-size 128M;",
        "    max-ncache-ttl 300;",
        "    recursive-clients 2000;",
        "    tcp-clients 500;",
        "    tcp-listen-queue 64;",
        "    zone-statistics no;",
        "    edns-udp-size 1232;",
        "    max-udp-size 1232;",
        "    querylog no;",
        "};",
        "",
        "controls {", f'    inet 127.0.0.1 port 953 allow {{ 127.0.0.1; }} keys {{ "{rndc_keyname()}"; }};', "};", "",
        "statistics-channels {", "    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };", "};", "",
        "logging {",
        "    channel main_log {",
        f'        file "{PATHS["log_dir"]}/named.log" versions {s["data"]["bind_log_versions"]} size {s["data"]["bind_log_size_mb"]}m;',
        "        severity info; print-time yes; print-severity yes; print-category yes;",
        "    };",
        "    category default      { main_log; };",
        "    category queries      { null; };",
        "    category lame-servers { null; };",
        "};", "",
        f'zone "{s["local"]["zone"]}" {{ type primary; file "{z}/db.local"; allow-update {{ none; }}; }};',
        f'zone "10.in-addr.arpa" {{ type primary; file "{z}/db.10"; allow-update {{ none; }}; }};']
    for zn in LOCAL_SUFFIXES[1:]:
        lines.append(f'zone "{zn}" {{ type primary; file "{z}/db.empty"; }};')
    return "\n".join(lines) + "\n"


def lua_str(v):
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


def dnsdist_hash(secret):
    """scrypt hash in dnsdist's own format, so the config never holds the plain secret ('' if unsupported)."""
    fd, tmp = tempfile.mkstemp(suffix=".lua")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(f'print("HASH=" .. hashPassword({lua_str(secret)}))\n')
        code, out = run([PATHS["dnsdist"], "--check-config", "-C", tmp], 30)
    finally:
        os.unlink(tmp)
    m = re.search(r"HASH=(\$scrypt\$\S+)", out)
    return m.group(1) if code == 0 and m else ""


def dnsdist_secrets():
    """Console key and web credentials, created once. Readable by the dashboard (group dnsdash)."""
    path = PATHS["dnsdist_secret"]
    try:
        with open(path) as f:
            d = json.load(f)
        if all(d.get(k) for k in ("console_key", "web_password", "api_key")):
            if "web_password_hash" not in d:
                d["web_password_hash"], d["api_key_hash"] = dnsdist_hash(d["web_password"]), dnsdist_hash(d["api_key"])
                write_atomic(path, json.dumps(d, indent=2), 0o640, PATHS["socket_group"])
            return d
    except (OSError, ValueError):
        pass
    d = {"console_key": base64.b64encode(secrets.token_bytes(32)).decode(),
         "web_password": secrets.token_urlsafe(24), "api_key": secrets.token_urlsafe(32),
         "web": "127.0.0.1:8083", "console": "127.0.0.1:5199"}
    d["web_password_hash"], d["api_key_hash"] = dnsdist_hash(d["web_password"]), dnsdist_hash(d["api_key"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_atomic(path, json.dumps(d, indent=2), 0o640, PATHS["socket_group"])
    return d


def render_dnsdist_conf(s, sec=None):
    sec = sec or dnsdist_secrets()
    r = s["resolver"]
    ncpu = os.cpu_count() or 2
    # one SO_REUSEPORT listener per core and address (kernel spreads queries over them); more threads than cores
    # only adds context switches and queueing delay, which is what low latency has to avoid
    listeners = max(1, min(ncpu, 4))
    sockets = max(2, min(ncpu, 4))              # UDP sockets per upstream: parallel receive without oversubscribing
    # "All interfaces" binds every address explicitly (not 0.0.0.0): answers always leave from the address that was
    # asked, and a systemd-resolved stub on 127.0.0.53 cannot block the start. New addresses are picked up by the scheduler.
    addrs = sorted(host_ips(), key=lambda a: (a != "127.0.0.1", ipaddress.ip_address(a))) if r["listen"] == ["any"] else r["listen"]
    acl = []
    for a in r["query_acl"]:
        acl += ["0.0.0.0/0", "::/0"] if a == "any" else ["127.0.0.0/8", "::1/128"] if a == "localhost" else [a]
    for a in ("127.0.0.0/8",):
        if a not in acl:
            acl.append(a)
    names = {"1.1.1.1": "Cloudflare 1.1.1.1", "1.0.0.1": "Cloudflare 1.0.0.1", "8.8.8.8": "Google 8.8.8.8",
             "8.8.4.4": "Google 8.8.4.4", "9.9.9.9": "Quad9 9.9.9.9", "149.112.112.112": "Quad9 149.112.112.112"}
    L = [
        "-- Managed by dnsdash-agent (VDNS). Edit through the dashboard's Settings page;",
        "-- manual changes here are overwritten on the next save.",
        "",
        "-- ---------------------------------------------------------------- performance",
        'setSecurityPollSuffix("")                   -- no periodic security-poll lookups',
        "setMaxUDPOutstanding(65535)                 -- in-flight queries per upstream socket",
        "setUDPMultipleMessagesVectorSize(64)        -- recvmmsg/sendmmsg batches",
        "setRingBuffersSize(20000, 16)               -- recent queries for the console (sharded, low lock contention)",
        "setUDPSocketBufferSizes(16777216, 16777216) -- 16 MB socket buffers absorb bursts (needs net.core.rmem_max)",
        "setUDPTimeout(1)                            -- a lost upstream packet frees its slot after 1 s",
        "setPayloadSizeOnSelfGeneratedAnswers(1232)  -- no IP fragmentation on answers dnsdist builds itself",
        "setTCPRecvTimeout(2)",
        "setTCPSendTimeout(2)",
        "setMaxTCPQueuedConnections(10000)",
        "setMaxTCPConnectionsPerClient(0)",
        "",
        "-- ---------------------------------------------------------------- clients",
        f'setACL({{{", ".join(lua_str(a) for a in acl)}}})',
        "setLocal(" + lua_str(addrs[0] + ":53") + ", {reusePort=true, tcpFastOpenQueueSize=256})",
    ]
    first = True
    for a in addrs:
        for _ in range(listeners):
            if first:
                first = False
                continue
            L.append("addLocal(" + lua_str(a + ":53") + ", {reusePort=true, tcpFastOpenQueueSize=256})")
    L += ["", "-- ---------------------------------------------------------------- upstreams (internet)"]
    for i, f in enumerate(r["forwarders"], 1):
        L.append(f'newServer({{address={lua_str(f + ":53")}, name={lua_str(names.get(f, "Upstream " + f))}, order={i}, '
                 f'sockets={sockets}, checkInterval=1, checkTimeout=500, maxCheckFailures=2, rise=1, useClientSubnet=false}})')
    zone = s["local"]["zone"]
    L += [
        "",
        "-- ---------------------------------------------------------------- BIND (local zones + Apple content caching)",
        f'newServer({{address="127.0.0.1:{int(PATHS["bind_port"])}", name="BIND local", pool="bind", order=1, sockets=2, '
        f'checkName={lua_str(zone + ".")}, checkType="SOA", mustResolve=true, checkInterval=1, maxCheckFailures=3, rise=1}})',
        f'setServerPolicy({r["policy"]})',
        "",
        "-- ---------------------------------------------------------------- packet caches",
        f'internet = newPacketCache({r["cache_entries"]}, {{maxTTL={r["max_cache_ttl"]}, minTTL=0, temporaryFailureTTL=30, '
        f'maxNegativeTTL={r["max_ncache_ttl"]}, staleTTL=60, numberOfShards={max(16, ncpu * 4)}, deferrableInsertLock=true, '
        f'keepStaleData={"true" if r["serve_stale"] else "false"}, parseECS=false, dontAge=false}})',
        'getPool(""):setCache(internet)',
        # local answers are flushed from this cache whenever records change, so they can stay cached for an hour
        'localcache = newPacketCache(20000, {maxTTL=3600, minTTL=0, temporaryFailureTTL=5, maxNegativeTTL=60, numberOfShards=4, deferrableInsertLock=true})',
        'getPool("bind"):setCache(localcache)',
    ]
    if r["serve_stale"]:
        L.append("setStaleCacheEntriesTTL(86400)              -- answer from expired cache while every upstream is down")
    L += ["", "-- ---------------------------------------------------------------- routing (first match wins)"]
    if r["rate_limit"]["enabled"]:
        ex = r["rate_limit"]["exempt"] or ["127.0.0.1/32"]
        L.append(f'addAction(AndRule({{NotRule(NetmaskGroupRule(newNMG({{{", ".join(lua_str(x) for x in ex)}}}))), '
                 f'MaxQPSIPRule({r["rate_limit"]["qps"]}, 32, 64)}}), TCAction())   -- over the limit: ask the client to retry over TCP')
    L.append("bindzones = newSuffixMatchNode()")
    for d in [zone] + LOCAL_SUFFIXES + r["local_suffixes"]:
        L.append(f"bindzones:add(newDNSName({lua_str(d + '.')}))")
    L.append('addAction(SuffixMatchNodeRule(bindzones, true), PoolAction("bind"))')
    if r["apple_to_bind"]:
        L.append('addAction(RegexRule("(^|\\\\.)_aaplcache\\\\._tcp\\\\."), PoolAction("bind"))')
    L += [
        "",
        "-- ---------------------------------------------------------------- management (loopback only)",
        f'controlSocket({lua_str(sec.get("console", "127.0.0.1:5199"))})',
        f'setKey({lua_str(sec["console_key"])})',
        'setConsoleACL("127.0.0.1/32")',
        f'webserver({lua_str(sec.get("web", "127.0.0.1:8083"))})',
    ]
    if sec.get("web_password_hash") and sec.get("api_key_hash"):
        L.append(f'setWebserverConfig({{password={lua_str(sec["web_password_hash"])}, apiKey={lua_str(sec["api_key_hash"])}, '
                 'acl="127.0.0.1/32", customHeaders={["X-Frame-Options"]="SAMEORIGIN"}})')
    else:
        L.append(f'setWebserverConfig({{password={lua_str(sec["web_password"])}, apiKey={lua_str(sec["api_key"])}, '
                 'acl="127.0.0.1/32", hashPlaintextCredentials=true, customHeaders={["X-Frame-Options"]="SAMEORIGIN"}})')
    return "\n".join(L) + "\n"


def dnsdist_console(cmd, timeout=20):
    return run([PATHS["dnsdist"], "-C", PATHS["dnsdist_conf"], "-c", "-e", cmd], timeout)


def check_dnsdist(path):
    code, out = run([PATHS["dnsdist"], "--check-config", "-C", path], 60)
    out = "\n".join(l for l in out.splitlines() if "plain-text" not in l and "hashPassword" not in l)
    return code, out


def render_local(s, serial):
    zone = s["local"]["zone"]
    out = [f"$ORIGIN {zone}.", soa(serial, zone).rstrip()]
    has_ns1 = any(r["name"] == "ns1" and r["type"] == "A" for r in s["local"]["records"])
    if not has_ns1:
        out.append("ns1 IN A 127.0.0.1")
    for r in s["local"]["records"]:
        val = f'"{r["value"]}"' if r["type"] == "TXT" else r["value"]
        ttl = f' {r["ttl"]}' if r["ttl"] else ""
        out.append(f'{r["name"]}{ttl} IN {r["type"]} {val}')
    return "\n".join(out) + "\n"


def render_reverse(s, serial):
    zone = s["local"]["zone"]
    out = [soa(serial, zone).rstrip()]
    seen = set()
    for r in s["local"]["records"]:
        if r["type"] != "A" or "*" in r["name"]:
            continue
        a = ipaddress.ip_address(r["value"])
        if a not in ipaddress.ip_network("10.0.0.0/8") or r["value"] in seen:
            continue
        seen.add(r["value"])
        o = r["value"].split(".")
        fq = f"{zone}." if r["name"] == "@" else f'{r["name"]}.{zone}.'
        out.append(f"{o[3]}.{o[2]}.{o[1]} IN PTR {fq}")
    return "\n".join(out) + "\n"


def render_empty(serial):
    return f"$TTL 86400\n@ IN SOA localhost. root.localhost. ( {serial} 3600 900 604800 3600 )\n@ IN NS localhost.\n"


def rpz_header(serial):
    return f"$TTL 300\n@ IN SOA localhost. root.localhost. ( {serial} 3600 600 86400 60 )\n@ IN NS localhost.\n"


def render_rpz_rules(domains, target, serial, wildcard=True):
    parts = [rpz_header(serial)]
    for d in domains:
        parts.append(f"{d} CNAME {target}\n")
        if wildcard:
            parts.append(f"*.{d} CNAME {target}\n")
    return "".join(parts)


def lists_dir():
    d = os.path.join(PATHS["state"], "lists")
    os.makedirs(d, exist_ok=True)
    return d


def list_status():
    try:
        return json.load(open(os.path.join(PATHS["state"], "lists.json")))
    except (OSError, ValueError):
        return {}


def write_rpz_lists(s, serial):
    """Union of all enabled, downloaded lists -> rpz.lists.db. Returns domain count."""
    allow = set(s["blocking"]["allow"])
    wild, exact = set(), set()
    for l in s["blocking"]["lists"]:
        if not l["enabled"]:
            continue
        p = os.path.join(lists_dir(), l["id"] + LIST_EXT)
        if not os.path.exists(p):
            continue
        with open(p) as f:
            for line in f:
                d = line.strip()
                if d and d not in allow and d not in PROTECTED:
                    (wild if l["wildcard"] else exact).add(d)
    exact -= wild
    path = os.path.join(PATHS["zones"], "rpz.lists.db")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(rpz_header(serial))
        for d in sorted(wild):
            f.write(f"{d} CNAME .\n*.{d} CNAME .\n")
        for d in sorted(exact):
            f.write(f"{d} CNAME .\n")
    os.chmod(tmp, 0o640)
    try:
        os.chown(tmp, 0, grp.getgrnam("bind").gr_gid)
    except (KeyError, PermissionError):
        pass
    os.replace(tmp, path)
    return len(wild) + len(exact)


def write_all(s):
    z, serial = PATHS["zones"], next_serial()
    os.makedirs(z, exist_ok=True)
    write_atomic(PATHS["named_conf"], render_named_conf(s), 0o644)
    write_atomic(os.path.join(z, "db.local"), render_local(s, serial))
    write_atomic(os.path.join(z, "db.10"), render_reverse(s, serial))
    write_atomic(os.path.join(z, "db.empty"), render_empty(serial))
    os.makedirs(os.path.dirname(PATHS["dnsdist_conf"]), exist_ok=True)
    write_atomic(PATHS["dnsdist_conf"], render_dnsdist_conf(s), 0o640, PATHS["dnsdist_group"])
    if s["blocking"]["enabled"]:
        write_atomic(os.path.join(z, "rpz.allow.db"), render_rpz_rules(s["blocking"]["allow"], "rpz-passthru.", serial))
        write_atomic(os.path.join(z, "rpz.block.db"), render_rpz_rules(s["blocking"]["block"], ".", serial))
        write_rpz_lists(s, serial)


MANAGED = ["db.local", "db.10", "db.empty", "rpz.allow.db", "rpz.block.db", "rpz.lists.db"]


def snapshot():
    d = os.path.join(PATHS["state"], "rollback")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for src in [PATHS["named_conf"], PATHS["settings"], PATHS["dnsdist_conf"]] + [os.path.join(PATHS["zones"], f) for f in MANAGED]:
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(d, os.path.basename(src)))
    return d


def restore(d):
    for name in os.listdir(d):
        dst = PATHS["named_conf"] if name == os.path.basename(PATHS["named_conf"]) else \
            PATHS["settings"] if name == os.path.basename(PATHS["settings"]) else \
            PATHS["dnsdist_conf"] if name == os.path.basename(PATHS["dnsdist_conf"]) else os.path.join(PATHS["zones"], name)
        shutil.copy2(os.path.join(d, name), dst)


def rndc(*args, timeout=120):
    return run([PATHS["rndc"], "-k", PATHS["rndc_key"], *args], timeout)


def restart_dnsdist():
    code, out = run([PATHS["systemctl"], "restart", PATHS["dnsdist_service"]], 60)
    if code == 0:
        for _ in range(20):
            if run([PATHS["systemctl"], "is-active", "--quiet", PATHS["dnsdist_service"]], 10)[0] == 0:
                return 0, ""
            time.sleep(0.25)
        code, out = 1, "dnsdist did not stay running"
    return code, out


def check_and_reload(snap, what):
    code, out = run([PATHS["checkconf"], "-z", PATHS["named_conf"]], 300)
    if code != 0:
        restore(snap)
        raise Bad("BIND rejected the new configuration, nothing was changed:\n" + "\n".join(
            l for l in out.splitlines() if "loaded serial" not in l)[-1500:])
    code, out = check_dnsdist(PATHS["dnsdist_conf"])
    if code != 0:
        restore(snap)
        raise Bad("dnsdist rejected the new configuration, nothing was changed:\n" + out[-1500:])
    code, out = rndc("reload")
    if code != 0:
        restore(snap)
        rndc("reload")
        raise Bad("BIND could not reload, the previous configuration was restored:\n" + out[-1000:])
    old = os.path.join(snap, os.path.basename(PATHS["dnsdist_conf"]))
    try:
        changed = open(old).read() != open(PATHS["dnsdist_conf"]).read()
    except OSError:
        changed = True
    if changed:
        code, out = restart_dnsdist()
        if code != 0:
            restore(snap)
            rndc("reload")
            restart_dnsdist()
            raise Bad("dnsdist did not start with the new settings, the previous configuration was restored:\n" + out[-1000:])
        return f"{what} applied. BIND reloaded and dnsdist restarted (its cache starts empty)."
    dnsdist_console('getPool("bind"):getCache():expunge(0)')
    return f"{what} applied. BIND reloaded."


def apply_settings(new, actor):
    with LOCK:
        s = validate(new)
        old = load_settings()
        snap = snapshot()
        try:
            save_settings(s)
            write_all(s)
        except OSError as ex:
            restore(snap)
            raise Bad(f"Could not write configuration files: {ex}")
        msg = check_and_reload(snap, "Settings")
        audit(actor, "settings", diff_summary(old, s))
        if s["blocking"]["enabled"] and any(l["enabled"] and not os.path.exists(os.path.join(lists_dir(), l["id"] + LIST_EXT))
                                            for l in s["blocking"]["lists"]):
            start_lists_job(actor, reason="new list enabled")
            msg += " Downloading the newly enabled blocklists in the background."
        return msg


def diff_summary(a, b):
    out = []
    for sec in ("resolver", "local", "blocking", "data"):
        for k in sorted(set(a.get(sec, {})) | set(b.get(sec, {}))):
            if a.get(sec, {}).get(k) != b.get(sec, {}).get(k):
                if k in ("lists", "records", "block", "allow"):
                    out.append(f"{sec}.{k} changed")
                else:
                    out.append(f"{sec}.{k}: {a.get(sec, {}).get(k)} -> {b.get(sec, {}).get(k)}")
    return "; ".join(out) or "no changes"


def quick_rule(args, actor):
    """Block or allow one domain without touching anything else (fast path)."""
    d = norm_domain(args.get("domain", ""))
    if not d:
        raise Bad("That is not a valid domain")
    op = args.get("op")
    if op not in ("block", "allow", "unblock", "unallow"):
        raise Bad("Unknown rule operation")
    with LOCK:
        s = load_settings()
        b = s["blocking"]
        if op == "block":
            if d in b["allow"]:
                b["allow"].remove(d)
            if d not in b["block"]:
                b["block"].append(d)
        elif op == "allow":
            if d in b["block"]:
                b["block"].remove(d)
            if d not in b["allow"]:
                b["allow"].append(d)
        elif op == "unblock" and d in b["block"]:
            b["block"].remove(d)
        elif op == "unallow" and d in b["allow"]:
            b["allow"].remove(d)
        enable = op == "block" and not b["enabled"]
        if enable:
            b["enabled"] = True
        msg = apply_settings(s, actor) if enable else None
        if msg is None:
            snap = snapshot()
            save_settings(s)
            if b["enabled"]:
                serial = next_serial()
                write_atomic(os.path.join(PATHS["zones"], "rpz.allow.db"), render_rpz_rules(b["allow"], "rpz-passthru.", serial))
                write_atomic(os.path.join(PATHS["zones"], "rpz.block.db"), render_rpz_rules(b["block"], ".", serial))
                for z in (RPZ_ALLOW, RPZ_BLOCK):
                    code, out = rndc("reload", z)
                    if code != 0:
                        restore(snap)
                        rndc("reload")
                        raise Bad("BIND could not load the rule: " + out[-500:])
                rndc("flushtree", d)
            msg = {"block": f"{d} is now blocked", "allow": f"{d} is now always allowed",
                   "unblock": f"{d} removed from your blocked domains", "unallow": f"{d} removed from your allowed domains"}[op]
            if not b["enabled"]:
                msg += " (blocking is currently switched off)"
        audit(actor, "rule", f"{op} {d}")
        return msg


# ----------------------------------------------------------------------------- blocklists
# Cached list files carry the parser version, so lists parsed by an older parser are downloaded again.
LIST_EXT = ".v2.txt"

# Whole-domain DNS rules only: "||example.com^", optionally with $important. Anything with a path,
# wildcard or other modifier ($third-party, $image, $domain=...) is a browser rule that blocks one URL
# or one context, never the whole host, so it is skipped rather than widened to the domain.
ABP_DOMAIN = re.compile(r"^\|\|([a-z0-9_.-]+)\^(?:\$important)?\|?$", re.I)

# Shared platforms: blocking the bare apex (and with it every subdomain) breaks large parts of the web.
# Lists may still block specific subdomains of these; only the apex itself is ignored.
PROTECTED = {
    "googleapis.com", "gstatic.com", "googleusercontent.com", "google.com", "googlevideo.com", "ggpht.com", "ytimg.com",
    "akamai.net", "akamaihd.net", "akamaized.net", "akamaiedge.net", "akadns.net", "edgekey.net", "edgesuite.net",
    "cloudfront.net", "amazonaws.com", "amazon.com", "azureedge.net", "azurewebsites.net", "azurefd.net", "windows.net",
    "msedge.net", "microsoft.com", "office.com", "office365.com", "live.com", "apple.com", "icloud.com", "mzstatic.com",
    "cdn-apple.com", "aaplimg.com", "fastly.net", "fastly.com", "fastlylb.net", "cloudflare.com", "cloudflare.net",
    "jsdelivr.net", "unpkg.com", "cdnjs.com", "github.com", "githubusercontent.com", "facebook.com", "fbcdn.net",
    "instagram.com", "cdninstagram.com", "whatsapp.net", "whatsapp.com", "twimg.com", "wp.com", "wordpress.com",
    "shopify.com", "shopifycdn.com", "b-cdn.net", "imgix.net", "digicert.com", "geotrust.com", "globalsign.com",
    "sectigo.com", "letsencrypt.org", "lencr.org", "pki.goog", "verisign.com", "entrust.net", "usertrust.com",
    "comodoca.com", "identrust.com", "godaddy.com", "starfieldtech.com", "amazontrust.com", "samsung.com",
    "samsungcloudsolution.com", "samsungcloudsolution.net", "gvt1.com", "gvt2.com", "1e100.net",
}


def parse_list(text, stats=None):
    out, skipped, rules = set(), 0, 0
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("!", "[", "#")):
            continue
        rules += 1
        if line.startswith("@@") or "##" in line or "#@#" in line or "#?#" in line or "#$#" in line or line.startswith("/"):
            skipped += 1
            continue
        if line.startswith("||") or line.startswith("|"):
            m = ABP_DOMAIN.match(line)
            if not m:
                skipped += 1
                continue
            line = m.group(1)
        else:
            line = line.split("#", 1)[0].strip()
            parts = line.split()
            if len(parts) >= 2 and re.match(r"^(0\.0\.0\.0|127\.0\.0\.1|::1?|::)$", parts[0]):
                line = parts[1]
            elif len(parts) == 1:
                line = parts[0]
            else:
                skipped += 1
                continue
            core = line[2:] if line.startswith("*.") else line
            if any(c in core for c in "/$^|*?=:@"):
                skipped += 1
                continue
        d = norm_domain(line)
        if d and d not in ("localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost"):
            out.add(d)
        elif d is None:
            skipped += 1
    if stats is not None:
        stats.update(rules=rules, skipped=skipped)
    return out


def download(url, limit=80 * 1024 * 1024):
    req = urllib.request.Request(url, headers={"User-Agent": "dnsdash-agent/1.0"})
    with urllib.request.urlopen(req, timeout=90) as r:
        if not r.geturl().startswith(("https://", "http://")):
            raise Bad("redirected to an unsupported address")
        data = r.read(limit + 1)
    if len(data) > limit:
        raise Bad("list is larger than 80 MB")
    return data.decode("utf-8", "replace")


def update_lists(actor, only=None):
    s = load_settings()
    st = list_status()
    for l in s["blocking"]["lists"]:
        if not l["enabled"] or (only and l["id"] != only):
            continue
        JOB["message"] = f"Downloading {l['name']}"
        rec = st.get(l["id"], {})
        try:
            t0 = time.time()
            ps = {}
            domains = parse_list(download(l["url"]), ps)
            if not domains:
                raise Bad("no valid domains found in the file")
            if ps["skipped"] > 4 * len(domains):
                raise Bad(f"this is a browser ad-block list: {ps['skipped']:,} of {ps['rules']:,} rules only work in a "
                          "browser. Use a DNS blocklist such as HaGeZi instead.")
            if len(domains) > 2_000_000:
                raise Bad(f"{len(domains):,} domains is more than the 2,000,000 limit")
            p = os.path.join(lists_dir(), l["id"] + LIST_EXT)
            with open(p + ".tmp", "w") as f:
                f.write("\n".join(sorted(domains)) + "\n")
            os.replace(p + ".tmp", p)
            rec.update(count=len(domains), skipped=ps["skipped"], updated=time.time(), error=None, seconds=round(time.time() - t0, 1))
        except Exception as ex:  # keep the previous copy of this list
            rec.update(error=str(ex)[:300], tried=time.time())
            log("list", l["id"], "failed:", ex)
        st[l["id"]] = rec
    write_atomic(os.path.join(PATHS["state"], "lists.json"), json.dumps(st), 0o600, "root")
    if not s["blocking"]["enabled"]:
        return "Lists downloaded. Blocking is switched off, so nothing changed in BIND."
    with LOCK:
        JOB["message"] = "Building the policy zone"
        snap = snapshot()
        total = write_rpz_lists(s, next_serial())
        JOB["message"] = f"Loading {total:,} domains into BIND"
        code, out = run([PATHS["checkzone"], "-q", RPZ_LISTS, os.path.join(PATHS["zones"], "rpz.lists.db")], 600)
        if code != 0:
            restore(snap)
            raise Bad("The combined blocklist zone failed validation: " + out[-500:])
        code, out = rndc("reload", RPZ_LISTS, timeout=600)
        if code != 0:
            restore(snap)
            rndc("reload")
            raise Bad("BIND could not load the blocklists: " + out[-500:])
        st["_total"] = {"count": total, "updated": time.time()}
        write_atomic(os.path.join(PATHS["state"], "lists.json"), json.dumps(st), 0o600, "root")
    audit(actor, "lists_update", f"{total} domains")
    return f"Blocklists updated: {total:,} domains loaded."


def start_lists_job(actor, reason="", only=None):
    if JOB["running"]:
        raise Bad("A blocklist update is already running")
    JOB.update(running=True, started=time.time(), finished=None, message="Starting", ok=None)

    def work():
        try:
            JOB["message"] = update_lists(actor, only)
            JOB["ok"] = True
        except Exception as ex:
            JOB["message"], JOB["ok"] = str(ex), False
        finally:
            JOB.update(running=False, finished=time.time())
    threading.Thread(target=work, daemon=True).start()
    return "Blocklist update started"


def prune_audit():
    days = load_settings()["data"]["audit_days"]
    path = PATHS["audit"]
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return
    cut = time.time() - days * 86400
    keep = [l for l in lines if not l.startswith("{") or json.loads(l).get("ts", 0) >= cut]
    if len(keep) != len(lines):
        with open(path + ".tmp", "w") as f:
            f.writelines(keep)
        os.replace(path + ".tmp", path)


def scheduler():
    n = 0
    while True:
        time.sleep(300)
        n += 1
        if n % 12 == 1:
            try:
                prune_audit()
            except Exception as ex:
                log("audit prune:", ex)
        try:
            s = load_settings()
            if s["resolver"]["listen"] == ["any"] and os.path.exists(PATHS["dnsdist_conf"]):
                have = set(re.findall(r'(?:setLocal|addLocal)\("([0-9.]+):53"', open(PATHS["dnsdist_conf"]).read()))
                if have and have != host_ips():
                    log("server addresses changed:", sorted(have), "->", sorted(host_ips()))
                    apply_settings(s, {"user": "scheduler", "ip": "-"})
        except Exception as ex:
            log("address check:", ex)
        try:
            s = load_settings()
            h = s["blocking"]["auto_update_hours"]
            if not s["blocking"]["enabled"] or JOB["running"]:
                continue
            st = list_status()
            missing = any(l["enabled"] and not os.path.exists(os.path.join(lists_dir(), l["id"] + LIST_EXT))
                          and time.time() - st.get(l["id"], {}).get("tried", 0) > 6 * 3600
                          for l in s["blocking"]["lists"])
            last = st.get("_total", {}).get("updated", 0)
            if missing or (h and time.time() - last >= h * 3600):
                start_lists_job({"user": "scheduler", "ip": "-"}, "missing lists" if missing else "scheduled")
        except Exception as ex:
            log("scheduler:", ex)


# ----------------------------------------------------------------------------- service / status
def service(args, actor):
    act = args.get("action")
    if act == "reload":
        code, out = rndc("reload")
        if code == 0:
            dnsdist_console('getPool("bind"):getCache():expunge(0)')
        msg = "BIND configuration and zones reloaded"
    elif act == "restart":
        code, out = run([PATHS["systemctl"], "restart", PATHS["named_service"]], 120)
        msg = "BIND restarted"
    elif act == "dd_restart":
        code, out = restart_dnsdist()
        msg = "dnsdist restarted (its cache starts empty)"
    elif act == "flush":
        code, out = rndc("flush")
        c2, o2 = dnsdist_console('getPool(""):getCache():expunge(0) getPool("bind"):getCache():expunge(0)')
        if code == 0 and c2 != 0:
            code, out = c2, o2
        msg = "dnsdist and BIND caches flushed"
    elif act == "flushname":
        d = norm_domain(args.get("name", ""))
        if not d:
            raise Bad("Enter a valid domain to flush")
        code, out = rndc("flushtree", d)
        n = lua_str(d + ".")
        c2, o2 = dnsdist_console(f'getPool(""):getCache():expungeByName(newDNSName({n}), DNSQType.ANY, true) '
                                 f'getPool("bind"):getCache():expungeByName(newDNSName({n}), DNSQType.ANY, true)')
        if code == 0 and c2 != 0:
            code, out = c2, o2
        msg = f"Cache cleared for {d} and everything under it"
    elif act == "validate":
        code, out = run([PATHS["checkconf"], "-z", PATHS["named_conf"]], 300)
        if code == 0:
            code, out = check_dnsdist(PATHS["dnsdist_conf"])
        msg = "dnsdist and BIND configurations are valid"
    else:
        raise Bad("Unknown action")
    if code != 0:
        raise Bad(f"{act} failed: {out[-800:]}")
    if act != "validate":
        audit(actor, "service", act + (" " + args.get("name", "") if act == "flushname" else ""))
    return msg


def status():
    code, active = run([PATHS["systemctl"], "is-active", PATHS["named_service"]], 10)
    _, since = run([PATHS["systemctl"], "show", "-p", "ActiveEnterTimestamp", "--value", PATHS["named_service"]], 10)
    _, rs = rndc("status", timeout=10)
    _, ver = run(["named", "-v"], 10)
    tail = []
    try:
        with open(os.path.join(PATHS["log_dir"], "named.log"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 16000))
            tail = f.read().decode("utf-8", "replace").splitlines()[-60:]
    except OSError:
        pass
    _, dd_active = run([PATHS["systemctl"], "is-active", PATHS["dnsdist_service"]], 10)
    _, dd_since = run([PATHS["systemctl"], "show", "-p", "ActiveEnterTimestamp", "--value", PATHS["dnsdist_service"]], 10)
    _, dd_ver = run([PATHS["dnsdist"], "--version"], 10)
    _, dd_log = run(["journalctl", "-u", PATHS["dnsdist_service"], "-n", "40", "--no-pager", "-o", "short-iso"], 10)
    return {"active": active.strip(), "since": since.strip(), "rndc": rs, "version": ver.strip(),
            "log": tail, "lists": list_status(), "job": dict(JOB),
            "dnsdist": {"active": dd_active.strip(), "since": dd_since.strip(),
                        "version": (dd_ver.splitlines() or [""])[0].strip(), "log": dd_log.splitlines()[-40:]}}


def get_audit():
    try:
        with open(PATHS["audit"], "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 40000))
            lines = f.read().decode("utf-8", "replace").splitlines()[-80:]
        return [json.loads(l) for l in lines if l.startswith("{")][::-1]
    except (OSError, ValueError):
        return []


def set_password(args, actor):
    user = str(args.get("user", "")).strip()
    pw = str(args.get("password", ""))
    if not re.match(r"^[A-Za-z0-9._-]{3,32}$", user):
        raise Bad("Username: 3-32 letters, numbers, dot, dash or underscore")
    if len(pw) < 10:
        raise Bad("Password must be at least 10 characters")
    path = PATHS["dash_config"]
    with open(path) as f:
        cfg = json.load(f)
    if not secrets.compare_digest(
            hashlib.pbkdf2_hmac("sha256", str(args.get("current", "")).encode(), bytes.fromhex(cfg["salt"]), int(cfg["iterations"])).hex(),
            cfg["hash"]):
        raise Bad("Current password is not correct")
    salt = secrets.token_bytes(16)
    cfg.update(user=user, salt=salt.hex(), iterations=600000,
               hash=hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 600000).hex())
    gid = os.stat(path).st_gid
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(tmp, 0o640)
    os.chown(tmp, 0, gid)
    os.replace(tmp, path)
    audit(actor, "password", f"login changed for {user}")
    return "Login updated. Use the new password next time you sign in."


# ----------------------------------------------------------------------------- socket server
def allowed_uids():
    ids = {0}
    try:
        ids.add(pwd.getpwnam(PATHS["client_user"]).pw_uid)
    except KeyError:
        pass
    return ids


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        cred = self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _, uid, _ = struct.unpack("3i", cred)
        if uid not in allowed_uids():
            return
        line = self.rfile.readline(4 * 1024 * 1024)
        try:
            req = json.loads(line)
            cmd, args, actor = req.get("cmd"), req.get("args") or {}, req.get("actor") or {}
            res = dispatch(cmd, args, actor)
            out = {"ok": True, "result": res}
        except Bad as ex:
            out = {"ok": False, "error": str(ex)}
        except Exception as ex:
            log("error in", line[:200], repr(ex))
            out = {"ok": False, "error": f"Internal error: {ex}"}
        self.wfile.write((json.dumps(out) + "\n").encode())


def dispatch(cmd, args, actor):
    if cmd == "get_settings":
        return {"settings": load_settings(), "lists": list_status(), "job": dict(JOB), "host_ips": sorted(host_ips())}
    if cmd == "apply_settings":
        return apply_settings(args.get("settings") or {}, actor)
    if cmd == "quick_rule":
        return quick_rule(args, actor)
    if cmd == "service":
        return service(args, actor)
    if cmd == "status":
        return status()
    if cmd == "lists_update":
        return start_lists_job(actor, "manual", args.get("only"))
    if cmd == "set_password":
        return set_password(args, actor)
    if cmd == "audit":
        return get_audit()
    raise Bad("Unknown command")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--render":
        # used by the installer: write settings (if missing) + all BIND files, no reload
        s = validate(load_settings()) if len(sys.argv) < 3 else validate(json.load(open(sys.argv[2])))
        save_settings(s)
        write_all(s)
        print("rendered", PATHS["named_conf"])
        return
    sock = PATHS["socket"]
    os.makedirs(os.path.dirname(sock), exist_ok=True)
    try:
        os.unlink(sock)
    except FileNotFoundError:
        pass
    old = os.umask(0o117)
    srv = Server(sock, Handler)
    os.umask(old)
    try:
        os.chown(sock, 0, grp.getgrnam(PATHS["socket_group"]).gr_gid)
    except KeyError:
        pass
    os.chmod(sock, 0o660)
    threading.Thread(target=scheduler, daemon=True).start()
    log("listening on", sock)
    srv.serve_forever()


if __name__ == "__main__":
    main()
DNSDASH_FILE_END
cat > "$APP/web/index.html" <<'DNSDASH_FILE_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>VDNS</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/app.css">
</head>
<body>
<svg width="0" height="0" class="defs" aria-hidden="true"><defs>
  <linearGradient id="iris-grad" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="100%" y2="0"><stop offset="0" stop-color="#0a84ff"/><stop offset=".55" stop-color="#5e5ce6"/><stop offset=".85" stop-color="#bf5af2"/><stop offset="1" stop-color="#ff375f"/></linearGradient>
  <linearGradient id="app-grad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2ea6ff"/><stop offset=".45" stop-color="#5e5ce6"/><stop offset=".8" stop-color="#bf5af2"/><stop offset="1" stop-color="#ff4f7b"/></linearGradient>
</defs></svg>
<div class="shell">
  <nav class="rail" aria-label="Main">
    <a class="brand" href="#/overview" aria-label="VDNS overview">
      <svg class="appicon" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="15" fill="url(#app-grad)"/><path class="v" d="M18 20l14 25 14-25"/><circle cx="18" cy="20" r="4.4"/><circle cx="46" cy="20" r="4.4"/><circle cx="32" cy="45" r="4.4"/></svg>
      <span class="brand-name">VDNS</span>
    </a>
    <a href="#/overview" data-page="overview"><svg viewBox="0 0 24 24"><rect x="3" y="3" width="7.5" height="9" rx="2"/><rect x="13.5" y="3" width="7.5" height="5" rx="2"/><rect x="3" y="15" width="7.5" height="6" rx="2"/><rect x="13.5" y="11" width="7.5" height="10" rx="2"/></svg><span>Overview</span></a>
    <a href="#/queries" data-page="queries"><svg viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h10"/></svg><span>Queries</span></a>
    <a href="#/settings" data-page="settings"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v2.6M12 18.6v2.6M4.2 7.4l2.2 1.3M17.6 15.3l2.2 1.3M4.2 16.6l2.2-1.3M17.6 8.7l2.2-1.3"/></svg><span>Settings</span></a>
    <div class="rail-foot">
      <button class="rail-btn" id="theme" type="button" title="Switch light or dark theme" aria-label="Switch theme"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path class="fill" d="M12 4a8 8 0 0 0 0 16z"/></svg></button>
      <form method="post" action="/logout"><button class="rail-btn" type="submit" title="Sign out" aria-label="Sign out"><svg viewBox="0 0 24 24"><path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M9 8l-4 4 4 4M5 12h10"/></svg></button></form>
    </div>
  </nav>

  <div class="main">
    <header class="top">
      <h1 id="page-title">Overview</h1>
      <div class="range" id="range">
        <div class="seg" id="win" role="group" aria-label="Time window">
          <button data-w="900">15m</button><button data-w="3600" class="on">1h</button><button data-w="21600">6h</button><button data-w="86400">24h</button>
          <button class="more" id="more-btn" type="button" aria-haspopup="true" aria-expanded="false"><span id="more-label">More</span><svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 4.5l3 3 3-3"/></svg></button>
        </div>
        <div class="menu" id="more-menu" role="menu" hidden>
          <button role="menuitem" data-w="604800">Last 7 days</button>
          <button role="menuitem" data-w="2592000">Last 30 days</button>
          <button role="menuitem" data-w="7776000">Last 90 days</button>
          <p class="menu-note" id="more-note"></p>
        </div>
      </div>
      <div class="host" id="hoststats" aria-label="Server">
        <div class="hs" id="hs-cpu"><span class="hs-k">CPU</span><span class="hs-v">–</span><i class="hs-bar"><b></b></i></div>
        <div class="hs" id="hs-ram"><span class="hs-k">RAM</span><span class="hs-v">–</span><i class="hs-bar"><b></b></i></div>
        <div class="hs" id="hs-disk"><span class="hs-k">Disk free</span><span class="hs-v">–</span><i class="hs-bar"><b></b></i></div>
        <div class="hs" id="hs-dd"><span class="hs-k">dnsdist</span><span class="hs-v">–</span></div>
        <span class="conn" id="conn" title="Connected"></span>
      </div>
    </header>

    <!-- ============================== OVERVIEW -->
    <section class="page" id="p-overview">
      <p class="dd-down" id="dd-down" hidden></p>
      <div class="tiles eight">
        <div class="tile hero"><p class="k">Queries per second</p><p class="v" id="dd-qps">–</p><p class="s" id="dd-qps-s">right now</p></div>
        <div class="tile c-blue"><p class="k">Queries</p><p class="v" id="k-queries">–</p><p class="s" id="k-queries-s">–</p></div>
        <div class="tile c-indigo"><p class="k">Cache hit ratio</p><p class="v" id="k-hit">–</p><div class="bar1"><i id="k-hit-b"></i></div></div>
        <div class="tile c-teal"><p class="k">Average answer</p><p class="v" id="k-avg">–</p><p class="s" id="k-avg-s">–</p></div>
        <div class="tile c-purple"><p class="k">95th percentile</p><p class="v" id="k-p95">–</p><p class="s">slowest 5% take longer</p></div>
        <div class="tile c-green"><p class="k">Under 1 ms</p><p class="v" id="k-fast">–</p><div class="bar1 green"><i id="k-fast-b"></i></div></div>
        <div class="tile c-teal"><p class="k">Clients</p><p class="v" id="k-clients">–</p><p class="s" id="k-top">–</p></div>
        <div class="tile c-blue"><p class="k">Busiest minute</p><p class="v" id="k-peak">–</p><p class="s" id="k-peak-s">–</p></div>
        <div class="tile c-orange"><p class="k">Doesn't exist</p><p class="v" id="k-nx">–</p><p class="s" id="k-nx-s">–</p></div>
        <div class="tile c-pink"><p class="k">Failures</p><p class="v" id="k-sf">–</p><p class="s" id="k-sf-s">–</p></div>
        <div class="tile c-indigo"><p class="k">Sent to BIND</p><p class="v" id="k-local">–</p><p class="s" id="k-local-s">–</p></div>
        <div class="tile c-blue"><p class="k">Asked upstream</p><p class="v" id="k-up">–</p><p class="s" id="k-up-s">–</p></div>
        <div class="tile c-pink"><p class="k">Upstream timeouts</p><p class="v" id="k-to">–</p><p class="s" id="k-to-s">–</p></div>
        <div class="tile c-green"><p class="k">Upstreams</p><p class="v" id="dd-ups">–</p><p class="s" id="dd-ups-s">right now</p></div>
        <div class="tile c-purple"><p class="k">Cached answers</p><p class="v" id="dd-cache">–</p><p class="s" id="dd-cache-s">right now</p></div>
        <div class="tile c-purple"><p class="k">dnsdist running for</p><p class="v" id="dd-up">–</p><p class="s" id="dd-ver">–</p></div>
      </div>

      <div class="grid">
        <article class="panel c6"><header><h2>Live traffic</h2><p class="legend"><i class="sw iris"></i>last 15 min<span class="muted" id="t-lat"></span></p></header><div class="chart" id="c-live"></div></article>
        <article class="panel c3"><header><h2>Results</h2><p class="hint" id="res-total"></p></header>
          <div class="donut-wrap"><svg class="donut" id="donut" viewBox="0 0 120 120"></svg><ul class="keys" id="res-keys"></ul></div><div class="chips" id="t-types"></div></article>
        <article class="panel c3"><header><h2>Answer speed</h2><p class="hint">dnsdist, since start</p></header><div class="bars cyan" id="dd-lat-bars"></div></article>

        <article class="panel c3"><header><h2>Traffic</h2><p class="legend"><i class="sw iris"></i>per minute</p></header><div class="chart" id="c-qpm"></div></article>
        <article class="panel c3"><header><h2>Response time</h2><p class="legend"><i class="sw iris"></i>avg <i class="sw cyan"></i>p95</p></header><div class="chart" id="c-lat"></div></article>
        <article class="panel c3"><header><h2>Queries and failures</h2><p class="legend"><i class="sw iris"></i>/s <i class="sw rose"></i>fail</p></header><div class="chart" id="c-ddq"></div></article>
        <article class="panel c3"><header><h2>Cache hits and CPU</h2><p class="legend"><i class="sw green"></i>hits <i class="sw amber"></i>CPU</p></header><div class="chart" id="c-ddc"></div></article>

        <article class="panel c6"><header><h2>Upstreams</h2><p class="hint"><span id="dd-policy"></span><a class="link" href="/dnsdist/ui/" target="_blank" rel="noopener">Classic console</a></p></header>
          <div class="scroll mid"><table class="tbl" id="dd-servers"><thead><tr><th>Server</th><th>Handles</th><th>State</th><th class="r">Q/s</th><th class="r">Latency</th><th class="r">Queries</th><th class="r">Waiting</th><th class="r">Dropped</th></tr></thead><tbody></tbody></table></div></article>
        <article class="panel c3"><header><h2>Routing</h2><p class="hint">first match wins</p></header>
          <div class="scroll mid"><table class="tbl" id="dd-rules"><thead><tr><th>Matches</th><th>Sent to</th><th class="r">Queries</th></tr></thead><tbody></tbody></table></div></article>
        <article class="panel c3"><header><h2>Answer times</h2><p class="hint" id="h-note"></p></header><div class="histo" id="h-lat"></div></article>

        <article class="panel c3"><header><h2>Most requested</h2><p class="hint" id="top-scope"></p></header><div class="bars" id="t-names"></div></article>
        <article class="panel c3"><header><h2>Doesn't exist</h2><p class="hint">NXDOMAIN</p></header><div class="bars rose" id="t-nx"></div></article>
        <article class="panel c3"><header><h2>Busiest clients</h2><a class="hint link" href="#/queries">Details</a></header><div class="bars cyan" id="t-clients"></div></article>
        <article class="panel c3"><header><h2>dnsdist health</h2><p class="hint">since start</p></header><dl class="facts two" id="dd-health"></dl></article>
      </div>

      <div class="section-head"><h2>BIND 9</h2><p class="hint" id="b-status">local zones and Apple content caching, behind dnsdist</p></div>
      <div class="tiles six">
        <div class="tile c-indigo"><p class="k">Queries since start</p><p class="v" id="b-q">–</p><p class="s" id="b-q-s">–</p></div>
        <div class="tile c-blue"><p class="k">Answered from zones</p><p class="v" id="b-auth">–</p><p class="s" id="b-auth-s">–</p></div>
        <div class="tile c-orange"><p class="k">Doesn't exist</p><p class="v" id="b-nx">–</p><p class="s" id="b-nx-s">–</p></div>
        <div class="tile c-pink"><p class="k">Failures</p><p class="v" id="b-sf">–</p><p class="s" id="b-sf-s">–</p></div>
        <div class="tile c-teal"><p class="k">Forwarded</p><p class="v" id="b-fwd">–</p><p class="s" id="b-fwd-s">names outside its zones</p></div>
        <div class="tile c-purple"><p class="k">Running for</p><p class="v" id="b-up">–</p><p class="s" id="b-ver">–</p></div>
      </div>
    </section>

    <!-- ============================== QUERIES -->
    <section class="page" id="p-queries" hidden>
      <div class="grid">
        <article class="panel c8 tall">
          <header><h2>Query stream</h2>
            <div class="filters">
              <input id="f-client" placeholder="Client IP" inputmode="decimal" aria-label="Filter by client IP">
              <input id="f-q" placeholder="Name contains" aria-label="Filter by name">
              <select id="f-rcode" aria-label="Filter by result"><option value="">All results</option><option>NOERROR</option><option>NXDOMAIN</option><option>SERVFAIL</option><option>REFUSED</option><option>NORESP</option></select>
              <label class="chk"><input type="checkbox" id="f-slow"> Slow</label>
              <label class="chk"><input type="checkbox" id="f-live" checked> Follow</label>
              <button class="btn ghost sm" id="f-clear" type="button">Clear</button>
            </div>
          </header>
          <div class="scroll"><table class="tbl" id="log"><thead><tr><th>Time</th><th>Client</th><th>Name</th><th>Type</th><th>Result</th><th class="r">Answer</th><th class="r"></th></tr></thead><tbody></tbody></table></div>
          <p class="foot" id="log-note"></p>
        </article>
        <div class="c4 stack">
        <article class="panel client-card" id="client-card">
          <header><h2>Client</h2><button class="btn ghost xs" type="button" id="cc-close" hidden>Show all</button></header>
          <p class="none" id="cc-empty">Select a client to see its details.</p>
          <div id="cc-body" hidden>
            <p class="cc-ip" id="cc-ip"></p><p class="cc-host" id="cc-host"></p>
            <div class="chips" id="cc-hints"></div>
            <dl class="facts two" id="cc-facts"></dl>
            <div class="cc-act" id="cc-act" aria-label="Activity in this window"></div>
            <h3 class="sub-h">Most requested</h3><div class="bars" id="cc-names"></div>
          </div>
        </article>
        <article class="panel tall">
          <header><h2>Clients</h2><p class="hint">Select one to focus on it</p></header>
          <div class="scroll"><table class="tbl" id="clients"><thead><tr><th data-k="client">Client</th><th class="r" data-k="n">Queries</th><th class="r" data-k="nx">Not found</th><th class="r" data-k="avg">Avg</th></tr></thead><tbody></tbody></table></div>
        </article>
        </div>
      </div>
    </section>

    <!-- ============================== BLOCKING (not used with dnsdist; kept for older settings) -->
    <section class="page" id="p-blocking" hidden>
      <div class="banner" id="blk-banner"><div><p class="b-title" id="blk-state">Loading</p><p class="b-sub" id="blk-sub"></p></div>
        <form class="quick" id="quick"><input id="quick-domain" placeholder="example.com" aria-label="Domain" autocomplete="off"><button class="btn rose sm" data-op="block" type="submit">Block</button><button class="btn ghost sm" data-op="allow" type="button" id="quick-allow">Always allow</button></form>
      </div>
      <div class="kpis four">
        <div class="kpi rose"><p class="k">Blocked queries</p><p class="v" id="bk-n">–</p><p class="s" id="bk-pct">–</p></div>
        <div class="kpi"><p class="k">Clients affected</p><p class="v" id="bk-clients">–</p><p class="s">had at least one query blocked</p></div>
        <div class="kpi"><p class="k">Domains on the block lists</p><p class="v" id="bk-domains">–</p><p class="s" id="bk-lists">–</p></div>
        <div class="kpi"><p class="k">Your own rules</p><p class="v" id="bk-rules">–</p><p class="s" id="bk-rules-s">–</p></div>
      </div>
      <div class="grid">
        <article class="panel c12"><header><h2>Blocked per minute</h2></header><div class="chart short" id="c-blk"></div></article>
        <article class="panel c5"><header><h2>Most blocked domains</h2><p class="hint">Allow one if it breaks something</p></header><div class="rows" id="bk-top"></div></article>
        <article class="panel c3"><header><h2>Clients blocked most</h2></header><div class="bars rose" id="bk-clients-top"></div></article>
        <article class="panel c4"><header><h2>Recently blocked</h2></header><div class="scroll mid"><table class="tbl" id="bk-log"><tbody></tbody></table></div></article>
      </div>
    </section>

    <!-- ============================== SETTINGS -->
    <section class="page" id="p-settings" hidden>
      <div class="settings">
        <nav class="subnav" aria-label="Settings sections">
          <a href="#/settings/resolver" data-sub="resolver">Resolver</a>
          <a href="#/settings/records" data-sub="records">Local records</a>
          <a href="#/settings/data" data-sub="data">Data &amp; logs</a>
          <a href="#/settings/service" data-sub="service">Service</a>
          <a href="#/settings/account" data-sub="account">Account</a>
          <a href="#/settings/activity" data-sub="activity">Activity</a>
        </nav>
        <div class="set-body">
          <form class="set" id="s-resolver" data-sub="resolver" novalidate>
            <div class="set-grid">
              <fieldset><legend>Internet upstreams</legend>
                <label>Upstream servers <span class="help">One IPv4 address per line, in order of preference (default: Cloudflare 1.1.1.1 and 1.0.0.1). dnsdist checks each one every second.</span><textarea name="forwarders" rows="4" spellcheck="false"></textarea></label>
                <label>Send each query to <select name="policy"><option value="leastOutstanding">The server with the fewest queries waiting (fastest)</option><option value="firstAvailable">The first healthy server in the list</option><option value="roundrobin">Each server in turn</option><option value="wrandom">A random server</option></select></label>
              </fieldset>
              <fieldset><legend>Sent to BIND</legend>
                <p class="help">Always sent to BIND: <span id="bind-zone">the local zone</span>, private reverse lookups (10.x, 172.16–31.x, 192.168.x, 169.254.x), resolver.arpa and home.arpa.</p>
                <label class="tog"><input type="checkbox" name="apple_to_bind"> Apple content caching lookups (<code>_aaplcache._tcp</code>)</label>
                <label>Also send these domains <span class="help">One per line; subdomains included. BIND must have a zone for them.</span><textarea name="local_suffixes" rows="3" spellcheck="false"></textarea></label>
              </fieldset>
              <fieldset><legend>Access</legend>
                <label>Allowed clients <span class="help">Networks allowed to query, one per line. <code>any</code> allows everyone.</span><textarea name="query_acl" rows="3" spellcheck="false"></textarea></label>
                <div class="field"><span>Listen on <span class="help">All interfaces answers on every IPv4 address.</span></span><div class="checks" id="listen-checks"></div></div>
              </fieldset>
              <fieldset><legend>Cache</legend>
                <div class="row2"><label>Answers to keep <input name="cache_entries" type="number" min="10000" max="20000000" step="10000"></label><label>Keep answers at most (s) <input name="max_cache_ttl" type="number" min="60" max="604800"></label></div>
                <div class="row2"><label>Keep "doesn't exist" at most (s) <input name="max_ncache_ttl" type="number" min="0" max="86400"></label><span></span></div>
                <label class="tog"><input type="checkbox" name="serve_stale"> Answer from expired cache when every upstream is down</label>
                <p class="help">About 1 KB of memory per cached answer at most; 1,000,000 answers stay well under 1 GB.</p>
              </fieldset>
              <fieldset class="wide"><legend>Rate limiting</legend>
                <label class="tog"><input type="checkbox" name="rl_enabled"> Limit queries per client</label>
                <div class="row2">
                  <label>Queries per second per client <input name="rl_qps" type="number" min="10" max="100000"></label>
                  <label>Exempt networks <span class="help">One per line.</span><textarea name="rl_exempt" rows="2" spellcheck="false"></textarea></label>
                </div>
                <p class="help">Clients over the limit are told to retry over TCP. Leave it off while many devices reach the server through one address (NAT).</p>
              </fieldset>
            </div>
            <div class="actions"><span class="note">Checked by dnsdist and BIND before going live and undone if rejected. Changes here restart dnsdist (under a second) and empty its cache.</span><button class="btn primary" type="submit">Save and apply</button></div>
          </form>

          <form class="set" id="s-blocklists" data-sub="blocklists" novalidate hidden>
            <div class="set-grid">
              <fieldset class="wide"><legend>Blocking</legend>
                <div class="row3">
                  <label class="tog big"><input type="checkbox" name="b_enabled"> Block domains on the lists below</label>
                  <label>Blocked domains answer with <select name="b_action"><option value="nxdomain">"Doesn't exist" (NXDOMAIN)</option><option value="nodata">"No address" (NODATA)</option></select></label>
                  <label>Update lists every <select name="b_auto"><option value="0">Never (manual)</option><option value="6">6 hours</option><option value="12">12 hours</option><option value="24">24 hours</option><option value="72">3 days</option><option value="168">week</option></select></label>
                </div>
              </fieldset>
              <fieldset class="wide"><legend>Lists</legend>
                <table class="tbl lists"><thead><tr><th>On</th><th>Name</th><th>Address</th><th title="Also block every subdomain">Subdomains</th><th class="r">Domains</th><th>Last update</th><th></th></tr></thead><tbody id="lists-body"></tbody></table>
                <div class="add-list"><input id="nl-name" placeholder="List name"><input id="nl-url" placeholder="https://example.com/blocklist.txt" class="grow"><button class="btn ghost sm" type="button" id="nl-add">Add list</button></div>
                <p class="help">Use DNS blocklists (domains, hosts or <code>||domain^</code> format). Browser ad-block lists such as EasyList or Easy Privacy mostly contain page rules that DNS cannot apply; VDNS keeps only their whole-domain rules.</p>
                <p class="help">Hosts files, plain domain lists and Adblock-style <code>||domain^</code> lists are understood. Bigger lists use more memory: 300,000 domains take roughly 150 MB.</p>
              </fieldset>
              <fieldset><legend>Your blocked domains</legend><label><span class="help">One per line; subdomains are blocked too.</span><textarea name="b_block" rows="7" spellcheck="false"></textarea></label></fieldset>
              <fieldset><legend>Always allowed</legend><label><span class="help">One per line; wins over every list.</span><textarea name="b_allow" rows="7" spellcheck="false"></textarea></label></fieldset>
            </div>
            <div class="actions"><span class="note" id="job-note"></span><button class="btn ghost" type="button" id="lists-update">Update lists now</button><button class="btn primary" type="submit">Save and apply</button></div>
          </form>

          <form class="set" id="s-records" data-sub="records" novalidate hidden>
            <fieldset class="wide"><legend>Local zone</legend>
              <label class="inline">Zone name <input name="zone" spellcheck="false"></label>
              <table class="tbl recs"><thead><tr><th>Name</th><th>Type</th><th>Value</th><th>TTL</th><th></th></tr></thead><tbody id="recs-body"></tbody></table>
              <button class="btn ghost sm" type="button" id="rec-add">Add record</button>
              <p class="help">Use <code>@</code> for the zone itself. Reverse (PTR) records are created automatically for A records in 10.0.0.0/8.</p>
            </fieldset>
            <div class="actions"><span class="note">Changes are checked by BIND before they go live.</span><button class="btn primary" type="submit">Save and apply</button></div>
          </form>

          <form class="set" id="s-data" data-sub="data" novalidate hidden>
            <div class="set-grid">
              <fieldset><legend>Dashboard history</legend>
                <label>Keep individual queries for <span class="help">Every lookup with its client, name and result. Feeds the query stream and exact top lists.</span>
                  <select name="query_hours"><option value="6">6 hours</option><option value="12">12 hours</option><option value="24">24 hours</option><option value="72">3 days</option><option value="168">7 days</option><option value="336">14 days</option><option value="720">30 days</option></select></label>
                <label>Keep statistics for <span class="help">Per-minute totals plus hourly top domains and clients. Powers the 7, 30 and 90 day views.</span>
                  <select name="stats_days"><option value="7">7 days</option><option value="30">30 days</option><option value="90">90 days</option><option value="180">180 days</option><option value="365">1 year</option></select></label>
              </fieldset>
              <fieldset><legend>Storage</legend>
                <dl class="facts" id="db-facts"></dl>
                <div class="btn-row"><button class="btn ghost sm" type="button" id="db-compact">Compact database</button><button class="btn rose sm" type="button" id="db-clear">Delete query history</button><button class="btn rose sm" type="button" id="db-reset">Delete all history and statistics</button></div>
                <p class="help">Each query uses about 200 bytes. 50 queries a second kept for 7 days is roughly 6 GB.</p>
              </fieldset>
              <fieldset><legend>BIND log</legend>
                <div class="row2"><label>Files to keep <input name="bind_log_versions" type="number" min="1" max="30"></label><label>Size of each file (MB) <input name="bind_log_size_mb" type="number" min="1" max="200"></label></div>
                <p class="help">/var/log/named/named.log rotates when it reaches this size.</p>
              </fieldset>
              <fieldset><legend>Activity history</legend>
                <label>Keep the record of changes for <select name="audit_days"><option value="30">30 days</option><option value="90">90 days</option><option value="180">180 days</option><option value="365">1 year</option><option value="730">2 years</option></select></label>
              </fieldset>
            </div>
            <div class="actions"><span class="note">Shorter periods delete older data within a minute of saving.</span><button class="btn primary" type="submit">Save and apply</button></div>
          </form>

          <div class="set" id="s-service" data-sub="service" hidden>
            <div class="svc">
              <div class="svc-states">
                <div class="svc-state"><span class="state-dot" id="svc-dd-dot"></span><div><p class="b-title" id="svc-dd-title">–</p><p class="b-sub" id="svc-dd-sub">–</p></div></div>
                <div class="svc-state"><span class="state-dot" id="svc-dot"></span><div><p class="b-title" id="svc-title">–</p><p class="b-sub" id="svc-sub">–</p></div></div>
              </div>
              <div class="svc-actions">
                <button class="btn ghost" data-act="validate">Check configuration</button>
                <button class="btn ghost" data-act="flush">Flush caches</button>
                <button class="btn ghost" data-act="reload">Reload BIND</button>
                <button class="btn rose" data-act="dd_restart">Restart dnsdist</button>
                <button class="btn rose" data-act="restart">Restart BIND</button>
              </div>
              <form class="quick" id="flushname"><input placeholder="Flush one domain, e.g. apple.com" id="fn-domain" autocomplete="off"><button class="btn ghost sm" type="submit">Flush</button></form>
            </div>
            <div class="grid">
              <article class="panel c6"><header><h2>dnsdist log</h2></header><pre class="pre log" id="svc-ddlog"></pre></article>
              <article class="panel c6"><header><h2>BIND status</h2></header><pre class="pre" id="svc-rndc"></pre></article>
              <article class="panel c12"><header><h2>BIND log</h2></header><pre class="pre log" id="svc-log"></pre></article>
            </div>
          </div>

          <form class="set narrow" id="s-account" data-sub="account" novalidate hidden>
            <fieldset><legend>Dashboard login</legend>
              <label>Username <input name="user" autocomplete="username"></label>
              <label>Current password <input name="current" type="password" autocomplete="current-password"></label>
              <label>New password <span class="help">At least 10 characters.</span><input name="password" type="password" autocomplete="new-password"></label>
              <label>Repeat new password <input name="password2" type="password" autocomplete="new-password"></label>
            </fieldset>
            <div class="actions"><button class="btn primary" type="submit">Change login</button></div>
          </form>

          <div class="set" id="s-activity" data-sub="activity" hidden>
            <article class="panel"><header><h2>Changes</h2><p class="hint">Every change made from this dashboard</p></header>
              <div class="scroll"><table class="tbl"><thead><tr><th>When</th><th>Who</th><th>From</th><th>What</th><th>Details</th></tr></thead><tbody id="audit-body"></tbody></table></div></article>
          </div>
        </div>
      </div>
    </section>
  </div>
</div>

<dialog id="confirm"><form method="dialog"><p id="confirm-text"></p><div class="actions"><button class="btn ghost" value="no">Cancel</button><button class="btn rose" value="yes" id="confirm-yes">Confirm</button></div></form></dialog>
<div class="toasts" id="toasts" aria-live="polite"></div>
<div id="tip" class="tip" hidden></div>
<script src="/app.js"></script>
</body>
</html>
DNSDASH_FILE_END
cat > "$APP/web/login.html" <<'DNSDASH_FILE_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>Sign in · VDNS</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/app.css">
</head>
<body class="login-body">
<svg width="0" height="0" class="defs" aria-hidden="true"><defs>
  <linearGradient id="app-grad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2ea6ff"/><stop offset=".45" stop-color="#5e5ce6"/><stop offset=".8" stop-color="#bf5af2"/><stop offset="1" stop-color="#ff4f7b"/></linearGradient>
</defs></svg>
<form class="login" method="post" action="/login" autocomplete="on">
  <svg class="appicon big" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="15" fill="url(#app-grad)"/><path class="v" d="M18 20l14 25 14-25"/><circle cx="18" cy="20" r="4.4"/><circle cx="46" cy="20" r="4.4"/><circle cx="32" cy="45" r="4.4"/></svg>
  <h1>VDNS</h1>
  <p class="muted">Sign in to manage your DNS resolver.</p>
  <label>Username <input name="user" autocomplete="username" required autofocus></label>
  <label>Password <input name="password" type="password" autocomplete="current-password" required></label>
  <p class="err" role="alert">{{MSG}}</p>
  <button type="submit">Sign in</button>
</form>
</body>
</html>
DNSDASH_FILE_END
cat > "$APP/web/app.css" <<'DNSDASH_FILE_END'
/* VDNS - Apple-style system colours, translucent materials and vector gradients.
   Blue carries traffic, pink/red marks failures, green healthy, orange warnings;
   the blue -> indigo -> purple -> pink gradient is the brand (icon, hero tile, chart lines). */
:root {
  color-scheme: dark;
  --bg: #050507;
  --bg-2: #141417;
  --panel: rgba(28, 28, 31, .72);
  --panel-solid: #1c1c1f;
  --raised: rgba(255, 255, 255, .06);
  --line: rgba(255, 255, 255, .08);
  --grid: rgba(255, 255, 255, .06);
  --text: #f5f5f7;
  --text-2: #a1a1a6;
  --muted: #6e6e73;
  --accent: #0a84ff;
  --accent-2: #409cff;
  --iris: #0a84ff;
  --iris-2: #64b5ff;
  --cyan: #64d2ff;
  --indigo: #5e5ce6;
  --purple: #bf5af2;
  --rose: #ff375f;
  --mint: #30d158;
  --amber: #ff9f0a;
  --teal: #40c8e0;
  --on-accent: #ffffff;
  --grad: linear-gradient(135deg, #0a84ff 0%, #5e5ce6 45%, #bf5af2 78%, #ff375f 100%);
  --glow-a: rgba(10, 132, 255, .20);
  --glow-b: rgba(191, 90, 242, .16);
  --glow-c: rgba(255, 55, 95, .08);
  --shadow: 0 1px 0 rgba(255, 255, 255, .04) inset, 0 18px 40px -28px rgba(0, 0, 0, .9);
  --seg: rgba(118, 118, 128, .24);
  --seg-on: #636366;
  --r: 18px;
  --rs: 10px;
  --ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --num: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", "Segoe UI", Roboto, sans-serif;
  --mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: light) {
  :root:not([data-theme="dark"]) {
    color-scheme: light;
    --bg: #f2f2f7; --bg-2: #e9e9ee; --panel: rgba(255, 255, 255, .78); --panel-solid: #ffffff; --raised: rgba(0, 0, 0, .04);
    --line: rgba(0, 0, 0, .07); --grid: rgba(0, 0, 0, .06);
    --text: #1d1d1f; --text-2: #6e6e73; --muted: #8e8e93;
    --accent: #007aff; --accent-2: #0a6cdf; --iris: #007aff; --iris-2: #0062cc; --cyan: #32ade6; --indigo: #5856d6; --purple: #af52de;
    --rose: #ff2d55; --mint: #34c759; --amber: #ff9500; --teal: #30b0c7;
    --glow-a: rgba(0, 122, 255, .14); --glow-b: rgba(175, 82, 222, .12); --glow-c: rgba(255, 45, 85, .06);
    --shadow: 0 1px 2px rgba(0, 0, 0, .04), 0 12px 32px -22px rgba(0, 0, 0, .28);
    --seg: rgba(118, 118, 128, .12); --seg-on: #ffffff;
  }
}
:root[data-theme="light"] {
  color-scheme: light;
  --bg: #f2f2f7; --bg-2: #e9e9ee; --panel: rgba(255, 255, 255, .78); --panel-solid: #ffffff; --raised: rgba(0, 0, 0, .04);
  --line: rgba(0, 0, 0, .07); --grid: rgba(0, 0, 0, .06);
  --text: #1d1d1f; --text-2: #6e6e73; --muted: #8e8e93;
  --accent: #007aff; --accent-2: #0a6cdf; --iris: #007aff; --iris-2: #0062cc; --cyan: #32ade6; --indigo: #5856d6; --purple: #af52de;
  --rose: #ff2d55; --mint: #34c759; --amber: #ff9500; --teal: #30b0c7;
  --glow-a: rgba(0, 122, 255, .14); --glow-b: rgba(175, 82, 222, .12); --glow-c: rgba(255, 45, 85, .06);
  --shadow: 0 1px 2px rgba(0, 0, 0, .04), 0 12px 32px -22px rgba(0, 0, 0, .28);
  --seg: rgba(118, 118, 128, .12); --seg-on: #ffffff;
}

* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; color: var(--text); font: 12.5px/1.4 var(--ui); -webkit-font-smoothing: antialiased; font-feature-settings: "tnum"; }
body {
  background:
    radial-gradient(900px 520px at 8% -8%, var(--glow-a), transparent 65%),
    radial-gradient(800px 480px at 92% -6%, var(--glow-b), transparent 62%),
    radial-gradient(700px 420px at 55% 112%, var(--glow-c), transparent 60%),
    var(--bg);
  background-attachment: fixed;
}
h1, h2, h3, p { margin: 0; }
a { color: inherit; }
button, input, select, textarea { font: inherit; color: inherit; }
:focus-visible { outline: 3px solid color-mix(in srgb, var(--accent) 55%, transparent); outline-offset: 2px; border-radius: 8px; }
[hidden] { display: none !important; }
code { font: 12px var(--mono); color: var(--purple); }
.defs { position: absolute; width: 0; height: 0; overflow: hidden; }

/* ---------------- app icon */
.appicon { width: 38px; height: 38px; display: block; filter: drop-shadow(0 6px 14px rgba(94, 92, 230, .35)); }
.appicon .v { fill: none; stroke: #fff; stroke-width: 5.2; stroke-linecap: round; stroke-linejoin: round; }
.appicon circle { fill: #fff; }

/* ---------------- shell */
.shell { display: grid; grid-template-columns: 80px 1fr; min-height: 100vh; }
.rail { position: sticky; top: 0; height: 100vh; display: flex; flex-direction: column; align-items: center; gap: 4px; padding: 16px 8px;
  background: var(--panel); border-right: 1px solid var(--line); z-index: 5;
  backdrop-filter: saturate(180%) blur(24px); -webkit-backdrop-filter: saturate(180%) blur(24px); }
.brand { display: flex; flex-direction: column; align-items: center; gap: 6px; margin-bottom: 16px; text-decoration: none; }
.brand-name { font: 700 12px var(--display); letter-spacing: .02em; color: var(--text); }
.rail a[data-page] { width: 62px; display: flex; flex-direction: column; align-items: center; gap: 3px; padding: 9px 0 7px; border-radius: 14px;
  text-decoration: none; color: var(--text-2); font-size: 10.5px; font-weight: 500; transition: color .2s, background .2s; }
.rail a[data-page] svg { width: 21px; height: 21px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
.rail a[data-page]:hover { color: var(--text); background: var(--raised); }
.rail a.on { color: var(--accent); background: color-mix(in srgb, var(--accent) 14%, transparent); }
.rail-foot { margin-top: auto; display: flex; flex-direction: column; gap: 8px; }
.rail-btn { width: 40px; height: 40px; border-radius: 12px; border: 1px solid var(--line); background: var(--raised); display: grid; place-items: center; cursor: pointer; color: var(--text-2); }
.rail-btn svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
.rail-btn .fill { fill: currentColor; stroke: none; }
.rail-btn:hover { color: var(--accent); }

.main { min-width: 0; padding: 0 18px 22px; }
.top { position: sticky; top: 0; z-index: 6; display: flex; align-items: center; gap: 16px; padding: 9px 18px 8px; margin: 0 -18px 8px; flex-wrap: wrap;
  background: color-mix(in srgb, var(--bg) 70%, transparent); border-bottom: 1px solid var(--line);
  backdrop-filter: saturate(180%) blur(24px); -webkit-backdrop-filter: saturate(180%) blur(24px); }
.top h1 { font: 700 21px/1.1 var(--display); letter-spacing: -.025em; min-width: 120px; }

/* segmented control, iOS style */
.range { position: relative; }
.seg { display: inline-flex; padding: 2px; gap: 2px; border-radius: 10px; background: var(--seg); }
.seg button { border: 0; background: none; color: var(--text); padding: 4px 11px; border-radius: 8px; cursor: pointer; font-size: 12.5px; font-weight: 500; display: inline-flex; align-items: center; gap: 4px; }
.seg button.on { background: var(--seg-on); box-shadow: 0 3px 8px rgba(0, 0, 0, .12), 0 0 0 .5px rgba(0, 0, 0, .04); font-weight: 600; }
.seg .more svg { width: 11px; height: 11px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; }
.menu { position: absolute; top: calc(100% + 6px); right: 0; min-width: 200px; padding: 6px; border-radius: 14px; background: var(--panel-solid);
  border: 1px solid var(--line); box-shadow: 0 24px 50px -18px rgba(0, 0, 0, .5); display: flex; flex-direction: column; gap: 2px; z-index: 20;
  animation: pop .18s ease-out; transform-origin: top right; }
@keyframes pop { from { opacity: 0; transform: scale(.96); } }
.menu button { text-align: left; border: 0; background: none; padding: 8px 10px; border-radius: 8px; cursor: pointer; color: var(--text); }
.menu button:hover { background: var(--raised); } .menu button.on { color: var(--accent); font-weight: 600; }
.menu button[disabled] { color: var(--muted); cursor: not-allowed; background: none; }
.menu-note { color: var(--muted); font-size: 11px; padding: 6px 10px 2px; border-top: 1px solid var(--line); margin-top: 2px; }

/* server stats chips */
.host { margin-left: auto; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.hs { display: grid; grid-template-columns: auto auto; grid-template-rows: auto 3px; column-gap: 8px; row-gap: 4px; align-items: baseline;
  padding: 4px 10px 5px; border-radius: 10px; background: var(--panel); border: 1px solid var(--line); min-width: 80px;
  backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }
.hs-k { font-size: 10.5px; color: var(--text-2); white-space: nowrap; }
.hs-v { white-space: nowrap; font: 600 13px var(--num); justify-self: end; }
.hs-bar { grid-column: 1 / -1; height: 3px; border-radius: 2px; background: var(--grid); overflow: hidden; }
.hs-bar b { display: block; height: 100%; width: 0; border-radius: 2px; background: var(--grad); transition: width .8s cubic-bezier(.3, .7, .2, 1); }
.hs.warn .hs-bar b { background: var(--amber); } .hs.bad .hs-bar b { background: var(--rose); }
.hs.warn .hs-v { color: var(--amber); } .hs.bad .hs-v { color: var(--rose); }
.conn { width: 8px; height: 8px; border-radius: 50%; background: var(--mint); box-shadow: 0 0 0 4px color-mix(in srgb, var(--mint) 20%, transparent); margin-left: 4px; }
.conn.down { background: var(--rose); box-shadow: 0 0 0 4px color-mix(in srgb, var(--rose) 22%, transparent); }

/* ---------------- tiles (compact stat cards) */
.tiles { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 8px; margin-bottom: 8px; }
.tiles.eight { grid-template-columns: repeat(8, minmax(0, 1fr)); }
.tile { position: relative; min-width: 0; padding: 7px 10px 7px; border-radius: 13px; background: var(--panel); border: 1px solid var(--line);
  box-shadow: var(--shadow); backdrop-filter: saturate(180%) blur(20px); -webkit-backdrop-filter: saturate(180%) blur(20px); }
.tile .k { font-size: 10.5px; font-weight: 600; color: var(--tint, var(--text-2)); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tile .v { font: 600 18px/1.15 var(--num); letter-spacing: -.02em; margin-top: 2px; white-space: nowrap; }
.tile .s { color: var(--text-2); font-size: 10.5px; margin-top: 1px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tile.hero { background: var(--grad); border-color: transparent; color: #fff; box-shadow: 0 16px 34px -20px rgba(94, 92, 230, .8); }
.tile.hero .k, .tile.hero .s { color: rgba(255, 255, 255, .86); }
.tile.hero .v { font-size: 21px; }
.c-blue { --tint: var(--iris); } .c-indigo { --tint: var(--indigo); } .c-purple { --tint: var(--purple); } .c-teal { --tint: var(--teal); }
.c-green { --tint: var(--mint); } .c-orange { --tint: var(--amber); } .c-pink { --tint: var(--rose); }
.v.good { color: var(--mint); } .v.warn { color: var(--amber); } .v.bad { color: var(--rose); }
.bar1 { height: 3px; margin-top: 6px; border-radius: 2px; background: var(--grid); overflow: hidden; }
.bar1 i { display: block; height: 100%; width: 0; border-radius: 2px; background: var(--grad); transition: width 1s cubic-bezier(.3, .7, .2, 1); }
.bar1.green i { background: linear-gradient(90deg, var(--mint), var(--teal)); }
.bar1.cyan i { background: var(--cyan); }
.section-head { display: flex; align-items: baseline; gap: 12px; margin: 12px 2px 8px; }
.section-head h2 { font: 700 16px var(--display); letter-spacing: -.02em; }
.dd-down { margin: 0 0 10px; padding: 11px 14px; border: 1px solid color-mix(in srgb, var(--rose) 40%, transparent); border-radius: 14px; background: color-mix(in srgb, var(--rose) 10%, var(--panel)); }

/* KPI band (blocking page, kept for older settings) */
.kpis { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin-bottom: 10px; }
.kpi { padding: 11px 13px; border-radius: 16px; background: var(--panel); border: 1px solid var(--line); min-width: 0; }
.kpi .k { font-size: 11.5px; color: var(--text-2); } .kpi .v { font: 600 22px var(--num); } .kpi .s { font-size: 11px; color: var(--text-2); }
.spark { display: block; width: 100%; height: 18px; margin-top: 3px; overflow: visible; }
.spark path.l { fill: none; stroke: var(--iris); stroke-width: 1.5; vector-effect: non-scaling-stroke; }
.spark path.a { fill: color-mix(in srgb, var(--iris) 14%, transparent); }

/* ---------------- grid & panels */
.grid { display: grid; grid-template-columns: repeat(12, minmax(0, 1fr)); gap: 8px; margin-bottom: 8px; }
.c3 { grid-column: span 3; } .c4 { grid-column: span 4; } .c5 { grid-column: span 5; } .c6 { grid-column: span 6; } .c7 { grid-column: span 7; }
.c8 { grid-column: span 8; } .c12 { grid-column: span 12; }
.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 15px; padding: 9px 12px 10px; min-width: 0; box-shadow: var(--shadow);
  display: flex; flex-direction: column; backdrop-filter: saturate(180%) blur(20px); -webkit-backdrop-filter: saturate(180%) blur(20px); }
.panel > header { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; margin-bottom: 6px; flex-wrap: wrap; }
.panel h2 { font: 600 13px var(--display); letter-spacing: -.01em; }
.stack { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.sub-h { font-size: 11.5px; color: var(--text-2); font-weight: 600; margin: 12px 0 6px; }
.hint { color: var(--text-2); font-size: 10.5px; }
.link { text-decoration: none; color: var(--accent); } .link:hover { text-decoration: underline; }
.muted { color: var(--muted); }
.legend { display: flex; align-items: center; gap: 4px; font-size: 10.5px; color: var(--text-2); }
.legend .muted { margin-left: 10px; }
.sw { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-left: 6px; }
.sw.iris { background: var(--grad); } .sw.rose { background: var(--rose); } .sw.cyan { background: var(--cyan); } .sw.amber { background: var(--amber); } .sw.green { background: var(--mint); }
.scope { font-size: 10.5px; color: var(--amber); }

.chart { height: 118px; position: relative; flex: 1; min-height: 108px; }

.chart.short { height: 108px; min-height: 100px; }
.chart svg { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; }
.axis { fill: var(--muted); font-size: 9.5px; font-variant-numeric: tabular-nums; }
.gl { stroke: var(--grid); stroke-width: 1; }
.ln-iris { fill: none; stroke: url(#iris-grad); stroke-width: 2.2; stroke-linejoin: round; stroke-linecap: round; }
.ln-cyan { fill: none; stroke: var(--cyan); stroke-width: 1.8; stroke-linejoin: round; }
.ln-rose { fill: none; stroke: var(--rose); stroke-width: 1.6; stroke-linejoin: round; }
.ln-green { fill: none; stroke: var(--mint); stroke-width: 2; stroke-linejoin: round; }
.ln-amber { fill: none; stroke: var(--amber); stroke-width: 1.6; stroke-linejoin: round; }
.xh { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 2 3; }
.hdot { stroke: var(--panel-solid); stroke-width: 2; }
.now-dot { fill: var(--purple); } .now-ring { fill: none; stroke: var(--purple); stroke-width: 1.4; animation: ping 2.6s ease-out infinite; transform-box: fill-box; transform-origin: center; }
@keyframes ping { 0% { transform: scale(.6); opacity: .9; } 100% { transform: scale(2.1); opacity: 0; } }
.peak { fill: var(--text-2); font-size: 10.5px; font-weight: 600; }
.empty { fill: var(--muted); font-size: 12px; }

/* donut */
.donut-wrap { display: flex; align-items: center; gap: 12px; flex: 1; min-height: 0; }
.donut { width: 92px; height: 92px; flex: none; transform: rotate(-90deg); }
.donut circle { fill: none; stroke-width: 12; stroke-linecap: butt; transition: stroke-dasharray .9s cubic-bezier(.3, .7, .2, 1), stroke-dashoffset .9s cubic-bezier(.3, .7, .2, 1); }
.donut .trk { stroke: var(--grid); }
.donut-c { transform: rotate(90deg); transform-origin: 60px 60px; }
.donut-c .big { font: 600 19px var(--num); fill: var(--text); text-anchor: middle; }
.donut-c .sm { font-size: 9.5px; fill: var(--text-2); text-anchor: middle; }
.keys { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 3px; flex: 1; min-width: 0; }
.keys li { display: grid; grid-template-columns: 8px 1fr auto; gap: 6px; align-items: center; font-size: 11px; }
.keys li i { width: 9px; height: 9px; border-radius: 50%; }
.keys li b { font-weight: 600; font-variant-numeric: tabular-nums; }
.keys li small { color: var(--text-2); font-size: 10px; margin-left: 4px; font-weight: 400; }
.t-NOERROR { background: var(--iris); stroke: var(--iris); } .t-BLOCKED { background: var(--purple); stroke: var(--purple); }
.t-NXDOMAIN { background: var(--amber); stroke: var(--amber); } .t-SERVFAIL { background: var(--rose); stroke: var(--rose); }
.t-NORESP { background: var(--muted); stroke: var(--muted); } .t-REFUSED, .t-other { background: var(--text-2); stroke: var(--text-2); }
.donut-wrap + .chips { margin-top: 7px; }

/* histogram */
.histo { display: grid; grid-template-columns: repeat(9, minmax(0, 1fr)); gap: 3px; align-items: end; flex: 1; min-height: 120px; }
.hcol { display: flex; flex-direction: column; justify-content: flex-end; height: 100%; gap: 4px; min-width: 0; }
.hbar { height: 0; min-height: 2px; border-radius: 6px 6px 3px 3px; background: linear-gradient(180deg, var(--mint), color-mix(in srgb, var(--mint) 55%, var(--teal))); transition: height .9s cubic-bezier(.3, .7, .2, 1); }
.hbar[data-tone="1"] { background: linear-gradient(180deg, var(--cyan), var(--iris)); } .hbar[data-tone="2"] { background: linear-gradient(180deg, #ffcc00, var(--amber)); } .hbar[data-tone="3"] { background: linear-gradient(180deg, var(--rose), var(--purple)); }
.hbar[data-tone="4"] { background: repeating-linear-gradient(135deg, var(--muted) 0 3px, transparent 3px 6px); border: 1px solid var(--muted); }
.hval, .hlab { font-size: 9px; text-align: center; color: var(--muted); white-space: nowrap; overflow: hidden; }
.hval { color: var(--text-2); }

/* ranked bars */
.bars { display: flex; flex-direction: column; gap: 4px; }
.bar-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 2px 8px; font-size: 11.5px; }
.bar-row .n { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.bar-row .c { color: var(--text-2); font-variant-numeric: tabular-nums; }
.bar-row .track { grid-column: 1 / -1; height: 3px; border-radius: 3px; background: var(--grid); overflow: hidden; }
.bar-row .fill { height: 100%; width: 0; border-radius: 3px; background: var(--grad); transition: width .9s cubic-bezier(.3, .7, .2, 1); }
.bars.rose .fill { background: linear-gradient(90deg, var(--amber), var(--rose)); } .bars.cyan .fill { background: linear-gradient(90deg, var(--teal), var(--iris)); }
.bar-row.click { cursor: pointer; } .bar-row.click:hover .n { color: var(--accent); }
.none { color: var(--text-2); font-size: 12px; padding: 4px 0; }

.fwd { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.fwd li { display: grid; grid-template-columns: 8px 1fr auto; gap: 0 9px; align-items: center; padding: 7px 10px; border-radius: 12px; background: var(--raised); }
.fwd .st { width: 8px; height: 8px; border-radius: 50%; background: var(--mint); grid-row: span 2; }
.fwd .st.warn { background: var(--amber); } .fwd .st.bad { background: var(--rose); }
.fwd .ip { font-weight: 600; font-size: 12px; } .fwd .meta { color: var(--text-2); font-size: 10.5px; grid-column: 2; }
.fwd .rtt { font: 600 15px var(--num); grid-row: 1 / span 2; grid-column: 3; } .fwd .rtt small { font-size: 10.5px; color: var(--text-2); font-weight: 500; }
.chips { display: flex; flex-wrap: wrap; gap: 5px; }
.chip { font-size: 10.5px; padding: 2px 8px; border-radius: 99px; background: var(--raised); color: var(--text-2); font-variant-numeric: tabular-nums; }
.chip b { color: var(--text); font-weight: 600; margin-right: 4px; }
.chip.hint-chip { background: color-mix(in srgb, var(--accent) 14%, transparent); color: var(--accent); font-weight: 600; }

/* ---------------- client card */
.client-card .cc-ip { font: 700 22px var(--num); letter-spacing: -.02em; background: var(--grad); -webkit-background-clip: text; background-clip: text; color: transparent; width: fit-content; }
.client-card .cc-host { color: var(--text-2); margin: 2px 0 8px; word-break: break-all; }
.client-card .facts { margin-top: 10px; }
.cc-act { display: grid; grid-template-columns: repeat(24, 1fr); gap: 2px; align-items: end; height: 38px; margin-top: 12px; }
.cc-act i { display: block; border-radius: 3px 3px 1px 1px; background: var(--grad); min-height: 3px; transition: height .6s; }

/* ---------------- tables & inputs */
.filters { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
input:not([type=checkbox]):not([type=radio]), select, textarea { padding: 7px 10px; border-radius: var(--rs); border: 1px solid var(--line); background: var(--raised); min-width: 0; }
.filters input:not([type=checkbox]) { width: 140px; }
textarea { width: 100%; resize: vertical; font: 12px/1.5 var(--mono); }
input:focus, select:focus, textarea:focus { border-color: var(--accent); outline: none; box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 22%, transparent); }
.chk { display: inline-flex; gap: 5px; align-items: center; color: var(--text-2); font-size: 12px; }
input[type=checkbox] { accent-color: var(--accent); width: 15px; height: 15px; }
.scroll { overflow: auto; max-height: 420px; margin: 0 -12px; padding: 0 12px; border-top: 1px solid var(--line); }
.scroll.mid { max-height: 196px; }
.tall .scroll { max-height: calc(100vh - 180px); }
.stack .tall .scroll { max-height: 46vh; }
.tbl { width: 100%; border-collapse: collapse; font-size: 11.5px; }
.tbl th { position: sticky; top: 0; background: var(--panel-solid); text-align: left; font-weight: 600; color: var(--text-2); padding: 5px 6px; border-bottom: 1px solid var(--line); white-space: nowrap; z-index: 1; }
.tbl th[data-k] { cursor: pointer; } .tbl th[data-k]:hover { color: var(--text); }
.tbl td { padding: 4px 6px; border-bottom: 1px solid var(--grid); white-space: nowrap; font-variant-numeric: tabular-nums; vertical-align: middle; }
.tbl td.name { white-space: normal; word-break: break-all; min-width: 180px; }
.tbl .r { text-align: right; }
.tbl tbody tr:hover { background: var(--raised); }
.tbl tr.sel { background: color-mix(in srgb, var(--accent) 12%, transparent); }
#clients tbody tr, td.cl { cursor: pointer; }
.tbl tr.fresh { animation: fresh 2s ease-out; }
@keyframes fresh { from { background: color-mix(in srgb, var(--accent) 14%, transparent); } to { background: transparent; } }
.rc { font-size: 10px; font-weight: 600; padding: 1px 7px; border-radius: 99px; }
.rc-NOERROR { color: var(--iris); background: color-mix(in srgb, var(--iris) 14%, transparent); }
.rc-NXDOMAIN { color: var(--amber); background: color-mix(in srgb, var(--amber) 15%, transparent); }
.rc-BLOCKED { color: var(--purple); background: color-mix(in srgb, var(--purple) 15%, transparent); }
.rc-SERVFAIL, .rc-NORESP, .rc-REFUSED, .rc-FORMERR { color: var(--rose); background: color-mix(in srgb, var(--rose) 14%, transparent); }
.lat-fast { color: var(--mint); } .lat-slow { color: var(--amber); } .lat-bad { color: var(--rose); }
.act { opacity: 0; transition: opacity .15s; }
tr:hover .act, .act:focus-visible { opacity: 1; }
.foot { color: var(--text-2); font-size: 11.5px; margin-top: 8px; }

/* ---------------- buttons */
.btn { border: 1px solid transparent; border-radius: 10px; padding: 7px 15px; font-weight: 600; cursor: pointer; white-space: nowrap; transition: filter .15s, background .15s, transform .1s; }
.btn:active { transform: scale(.98); }
.btn.sm { padding: 5px 12px; font-size: 12px; }
.btn.xs { padding: 2px 9px; font-size: 11px; border-radius: 8px; }
.btn.primary { background: var(--accent); color: var(--on-accent); }
.btn.rose { background: color-mix(in srgb, var(--rose) 14%, transparent); color: var(--rose); }
.btn.ghost { background: var(--raised); border-color: var(--line); color: var(--text); }
.btn:hover { filter: brightness(1.08); }
.btn[disabled] { opacity: .55; cursor: progress; }
.btn-row { display: flex; gap: 8px; flex-wrap: wrap; }

/* ---------------- blocking page (kept for older settings) */
.banner { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; padding: 13px 16px; margin-bottom: 10px; border-radius: var(--r); border: 1px solid var(--line); background: var(--panel); }
.b-title { font: 600 16px var(--display); }
.b-sub { color: var(--text-2); font-size: 12px; }
.quick { display: flex; gap: 6px; margin-left: auto; }
.quick input { width: 230px; }
.rows { display: flex; flex-direction: column; }
.brow { display: grid; grid-template-columns: minmax(0, 1fr) auto auto; gap: 10px; align-items: center; padding: 5px 0; border-bottom: 1px solid var(--grid); font-size: 12px; }
.brow .n { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; } .brow .src { color: var(--text-2); font-size: 10.5px; margin-left: 6px; } .brow .c { color: var(--text-2); }

/* ---------------- settings */
.settings { display: grid; grid-template-columns: 180px 1fr; gap: 14px; align-items: start; }
.subnav { position: sticky; top: 76px; display: flex; flex-direction: column; gap: 2px; background: var(--panel); border: 1px solid var(--line); border-radius: var(--r); padding: 6px;
  backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }
.subnav a { text-decoration: none; padding: 8px 11px; border-radius: 10px; color: var(--text); font-weight: 500; }
.subnav a:hover { background: var(--raised); }
.subnav a.on { background: var(--accent); color: #fff; }
.set-body { min-width: 0; }
.set-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
fieldset { margin: 0; border: 1px solid var(--line); border-radius: var(--r); background: var(--panel); padding: 13px 15px 15px; display: flex; flex-direction: column; gap: 10px; min-width: 0;
  box-shadow: var(--shadow); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }
fieldset.wide { grid-column: 1 / -1; }
legend { float: left; width: 100%; font: 600 14px var(--display); padding: 0; margin: 0 0 2px; }
legend + * { clear: both; }
.set label, .field { display: flex; flex-direction: column; gap: 4px; color: var(--text-2); font-size: 12px; }
.set label.tog { flex-direction: row; align-items: center; gap: 8px; color: var(--text); }
.set label.tog.big { font-weight: 600; font-size: 13.5px; }
.set label.inline { flex-direction: row; align-items: center; gap: 10px; }
.help { color: var(--muted); font-size: 11px; }
.row2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.row3 { display: grid; grid-template-columns: 1.2fr 1fr 1fr; gap: 14px; align-items: end; }
.checks { display: flex; flex-wrap: wrap; gap: 10px; color: var(--text); }
.checks label { flex-direction: row; align-items: center; gap: 6px; color: var(--text); }
.checks .all-ifaces { flex-basis: 100%; font-weight: 600; }
.checks label:has(input:disabled) { opacity: .6; }
.actions { display: flex; align-items: center; justify-content: flex-end; gap: 10px; margin-top: 12px; flex-wrap: wrap; }
.note { color: var(--text-2); font-size: 11.5px; margin-right: auto; }
.set.narrow { max-width: 460px; }
.facts { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; margin: 0; font-size: 11.5px; }
.facts.two { grid-template-columns: 1fr auto; }
.facts dt { color: var(--text-2); } .facts dd { margin: 0; text-align: right; font-weight: 600; font-variant-numeric: tabular-nums; }
.facts dd.warn { color: var(--amber); }
.tbl.lists td, .tbl.recs td { white-space: normal; }
.tbl.lists input:not([type=checkbox]), .tbl.recs input, .tbl.recs select { width: 100%; padding: 4px 7px; }
.tbl.lists .err { color: var(--rose); font-size: 11px; }
.tbl.lists .url { max-width: 380px; word-break: break-all; color: var(--text-2); font-size: 11.5px; }
.add-list { display: flex; gap: 6px; } .add-list .grow { flex: 1; }
.svc { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; background: var(--panel); border: 1px solid var(--line); border-radius: var(--r); padding: 13px 15px; margin-bottom: 10px; box-shadow: var(--shadow); }
.svc-states { display: flex; flex-direction: column; gap: 10px; margin-right: auto; }
.svc-state { display: flex; align-items: center; gap: 12px; }
.state-dot { width: 10px; height: 10px; border-radius: 50%; background: var(--muted); box-shadow: 0 0 0 4px color-mix(in srgb, var(--muted) 20%, transparent); }
.state-dot.ok { background: var(--mint); box-shadow: 0 0 0 4px color-mix(in srgb, var(--mint) 22%, transparent); }
.state-dot.bad { background: var(--rose); box-shadow: 0 0 0 4px color-mix(in srgb, var(--rose) 22%, transparent); }
.svc-actions { display: flex; gap: 6px; flex-wrap: wrap; }
.pre { margin: 0; font: 11.5px/1.5 var(--mono); color: var(--text-2); white-space: pre-wrap; word-break: break-word; max-height: 380px; overflow: auto; background: var(--raised); border-radius: 12px; padding: 10px; }
.pre.log { white-space: pre; }

/* ---------------- feedback */
.toasts { position: fixed; right: 18px; bottom: 18px; display: flex; flex-direction: column; gap: 8px; z-index: 60; max-width: min(460px, calc(100vw - 36px)); }
.toast { background: var(--panel-solid); border: 1px solid var(--line); border-radius: 14px; padding: 11px 14px 11px 34px; box-shadow: 0 20px 44px -18px rgba(0, 0, 0, .45);
  white-space: pre-wrap; animation: slidein .35s cubic-bezier(.3, .7, .2, 1); font-size: 12.5px; position: relative; }
.toast::before { content: ""; position: absolute; left: 13px; top: 15px; width: 9px; height: 9px; border-radius: 50%; background: var(--mint); }
.toast.err::before { background: var(--rose); }
.toast.out { opacity: 0; transform: translateY(8px); transition: opacity .3s, transform .3s; }
@keyframes slidein { from { opacity: 0; transform: translateY(12px); } }
dialog { border: 1px solid var(--line); background: var(--panel-solid); color: var(--text); border-radius: 20px; padding: 22px; max-width: 440px; box-shadow: 0 30px 60px -20px rgba(0, 0, 0, .55); }
dialog::backdrop { background: rgba(0, 0, 0, .35); backdrop-filter: blur(6px); }
.tip { position: fixed; z-index: 70; pointer-events: none; background: var(--panel-solid); border: 1px solid var(--line); border-radius: 12px; padding: 8px 11px; font-size: 11.5px;
  box-shadow: 0 16px 32px -14px rgba(0, 0, 0, .45); font-variant-numeric: tabular-nums; }
.tip .row { display: flex; align-items: center; gap: 6px; }
.tip .row:first-child { font-weight: 600; margin-bottom: 2px; }
.tip .sw { margin-left: 0; }

/* ---------------- login */
.login-body { display: grid; place-items: center; min-height: 100vh; padding: 16px; }
.login { width: 100%; max-width: 350px; background: var(--panel); border: 1px solid var(--line); border-radius: 26px; padding: 32px 28px 28px;
  display: flex; flex-direction: column; gap: 13px; box-shadow: var(--shadow); backdrop-filter: saturate(180%) blur(28px); -webkit-backdrop-filter: saturate(180%) blur(28px); }
.login .appicon.big { width: 62px; height: 62px; margin-bottom: 4px; }
.login h1 { font: 700 28px/1.1 var(--display); letter-spacing: -.025em; }
.login .muted { font-size: 12.5px; color: var(--text-2); }
.login label { display: flex; flex-direction: column; gap: 5px; color: var(--text-2); }
.login input { padding: 11px 12px; border-radius: 12px; }
.login .err { color: var(--rose); min-height: 1em; }
.login button { border: 0; border-radius: 12px; padding: 11px; margin-top: 4px; background: var(--grad); color: #fff; font-weight: 600; cursor: pointer; box-shadow: 0 12px 26px -14px rgba(94, 92, 230, .9); }
.login button:hover { filter: brightness(1.06); }

/* ---------------- responsive */
@media (max-width: 1280px) {
  .tiles.eight { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .tiles.six { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .c3 { grid-column: span 6; } .c5, .c4 { grid-column: span 6; } .c6, .c7, .c8 { grid-column: span 12; }
}
@media (max-width: 1100px) { .hs-bar { display: none; } .hs { grid-template-rows: auto; min-width: 0; } }
@media (max-width: 860px) {
  .shell { grid-template-columns: 1fr; }
  .rail { position: fixed; bottom: 0; top: auto; left: 0; right: 0; height: 64px; flex-direction: row; justify-content: space-around; padding: 6px; border-right: 0; border-top: 1px solid var(--line); }
  .brand, .rail-foot form { display: none; }
  .rail-foot { margin: 0; flex-direction: row; }
  .main { padding: 0 12px 80px; }
  .top { margin: 0 -12px 6px; padding-left: 12px; padding-right: 12px; }
  .host { margin-left: 0; width: 100%; }
  .hs { flex: 1 1 40%; }
  .tiles, .tiles.six, .tiles.eight { grid-template-columns: 1fr 1fr; }
  .kpis { grid-template-columns: 1fr 1fr; }
  .grid > *, .grid > .stack { grid-column: span 12 !important; }
  .settings { grid-template-columns: 1fr; }
  .subnav { position: static; flex-direction: row; overflow-x: auto; }
  .set-grid, .row2, .row3 { grid-template-columns: 1fr; }
  .quick { margin-left: 0; width: 100%; } .quick input { flex: 1; width: auto; }
  .donut { width: 116px; height: 116px; }
  .menu { right: auto; left: 0; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation: none !important; transition: none !important; }
}
DNSDASH_FILE_END
cat > "$APP/web/app.js" <<'DNSDASH_FILE_END'
"use strict";
(() => {
  // ================================================================ helpers
  const $ = (id) => document.getElementById(id);
  const SVGNS = "http://www.w3.org/2000/svg";
  const root = document.documentElement;
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const el = (tag, attrs = {}, text) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) { if (v === false || v == null) continue; if (k === "class") e.className = v; else e.setAttribute(k, v === true ? "" : v); }
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  };
  const sv = (tag, attrs = {}) => { const e = document.createElementNS(SVGNS, tag); for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); return e; };
  const nf = new Intl.NumberFormat();
  const compact = (n) => n == null ? "–" : n >= 1e9 ? (n / 1e9).toFixed(1) + "B" : n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e4 ? (n / 1e3).toFixed(1) + "K" : nf.format(Math.round(n));
  const pctf = (v, d = 1) => v == null ? "–" : v.toFixed(d) + "%";
  const ms = (v) => v == null ? "–" : v < 1 ? v.toFixed(2) + " ms" : v < 10 ? v.toFixed(1) + " ms" : nf.format(Math.round(v)) + " ms";
  const tclock = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const tsec = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const tfull = (t) => new Date(t * 1000).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
  const ago = (t) => { const s = Date.now() / 1000 - t; return s < 90 ? "just now" : s < 5400 ? Math.round(s / 60) + " min ago" : s < 172800 ? Math.round(s / 3600) + " h ago" : Math.round(s / 86400) + " days ago"; };
  const niceMax = (v) => { if (!(v > 0)) return 1; const p = Math.pow(10, Math.floor(Math.log10(v))); for (const m of [1, 2, 4, 6, 8, 10]) if (m * p >= v) return m * p; return 10 * p; };
  const ease = (t) => 1 - Math.pow(1 - t, 3);
  const lerp = (a, b, k) => a + (b - a) * k;

  // ================================================================ api, toasts, confirm
  let CSRF = "";
  let lastOk = 0;
  function setLive(ok, ts) {
    const c = $("conn");
    if (ok) { lastOk = Date.now(); c.classList.remove("down"); c.title = "Connected · updated " + tsec(ts || Date.now() / 1000); }
    else { c.classList.add("down"); c.title = "Connection lost, retrying"; }
  }
  setInterval(() => { if (lastOk && Date.now() - lastOk > 20000) setLive(false); }, 5000);
  async function api(path) {
    let r;
    try { r = await fetch(path, { credentials: "same-origin", cache: "no-store" }); } catch (e) { setLive(false); throw e; }
    if (r.status === 401) { location.href = "/login"; throw new Error("auth"); }
    if (!r.ok) { let msg = path + " " + r.status; try { msg = (await r.json()).error || msg; } catch (e) { /* not json */ } if (r.status >= 500 && r.status !== 502) setLive(false); throw new Error(msg); }
    return r.json();
  }
  async function post(path, body) {
    const r = await fetch(path, { method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json", "X-CSRF": CSRF }, body: JSON.stringify(body || {}) });
    if (r.status === 401) { location.href = "/login"; throw new Error("Session expired"); }
    let data = {};
    try { data = await r.json(); } catch (e) { /* empty */ }
    if (!r.ok) throw new Error(data.error || "Request failed (" + r.status + ")");
    return data.message;
  }
  function toast(msg, err) {
    const t = el("div", { class: "toast" + (err ? " err" : ""), role: err ? "alert" : "status" }, msg);
    $("toasts").append(t);
    setTimeout(() => { t.classList.add("out"); setTimeout(() => t.remove(), 350); }, err ? 9000 : 4500);
  }
  function confirmBox(text, yes) {
    const d = $("confirm");
    $("confirm-text").textContent = text;
    $("confirm-yes").textContent = yes || "Confirm";
    d.showModal();
    return new Promise((res) => d.addEventListener("close", () => res(d.returnValue === "yes"), { once: true }));
  }
  async function busy(btn, fn) {
    if (btn) btn.disabled = true;
    try { return await fn(); } finally { if (btn) btn.disabled = false; }
  }

  // ================================================================ theme
  try { const t = localStorage.getItem("dd-theme"); if (t === "light" || t === "dark") root.dataset.theme = t; } catch (e) { /* none */ }
  $("theme").addEventListener("click", () => {
    const cur = root.dataset.theme || (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
    root.dataset.theme = cur === "light" ? "dark" : "light";
    try { localStorage.setItem("dd-theme", root.dataset.theme); } catch (e) { /* none */ }
  });

  // ================================================================ tooltip
  const tip = $("tip");
  function showTip(x, y, rows) {
    tip.replaceChildren();
    for (const r of rows) { const d = el("div", { class: "row" }); if (r.sw) d.append(el("i", { class: "sw " + r.sw })); d.append(document.createTextNode(r.t)); tip.append(d); }
    tip.hidden = false;
    const w = tip.offsetWidth, h = tip.offsetHeight;
    tip.style.left = Math.max(8, Math.min(window.innerWidth - w - 8, x + 14)) + "px";
    tip.style.top = (y - h - 12 < 8 ? y + 18 : y - h - 12) + "px";
  }
  const hideTip = () => { tip.hidden = true; };

  // ================================================================ animated numbers
  function tween(node, value, fmt) {
    if (value == null || Number.isNaN(value)) { node.textContent = "–"; node.dataset.v = ""; return; }
    const from = node.dataset.v ? +node.dataset.v : 0;
    node.dataset.v = value;
    if (reduceMotion || from === value) { node.textContent = fmt(value); return; }
    const t0 = performance.now();
    const step = (now) => {
      if (+node.dataset.v !== value) return;
      const k = Math.min(1, (now - t0) / 700);
      node.textContent = fmt(lerp(from, value, ease(k)));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }
  function tone(node, cls) { node.classList.remove("good", "warn", "bad"); if (cls) node.classList.add(cls); }
  function animateArrays(owner, from, to, draw) {
    owner._anim = (owner._anim || 0) + 1;
    const id = owner._anim;
    if (reduceMotion || !from) { draw(to, 1); return; }
    const t0 = performance.now();
    const step = (now) => {
      if (owner._anim !== id) return;
      const k = ease(Math.min(1, (now - t0) / 650));
      draw(to.map((arr, s) => Array.isArray(arr) ? arr.map((v, i) => v == null ? null : lerp(from[s] && from[s][i] != null ? from[s][i] : 0, v, k)) : lerp(from[s] || 0, arr, k)), k);
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  // ================================================================ path helpers
  function smoothPath(pts, base) {
    if (!pts.length) return "";
    let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
      const c1y = Math.min(base, p1[1] + (p2[1] - p0[1]) / 6), c2y = Math.min(base, p2[1] - (p3[1] - p1[1]) / 6);
      d += `C${(p1[0] + (p2[0] - p0[0]) / 6).toFixed(1)},${c1y.toFixed(1)} ${(p2[0] - (p3[0] - p1[0]) / 6).toFixed(1)},${c2y.toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
    }
    return d;
  }
  const linePath = (pts) => pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + "," + p[1].toFixed(1)).join("");
  function gradients(svg, pre, W) {
    const defs = sv("defs");
    // brand gradient along the x axis, in this chart's own coordinates (a shared one would collapse to one colour)
    const lg = sv("linearGradient", { id: pre + "-line", gradientUnits: "userSpaceOnUse", x1: 0, y1: 0, x2: W, y2: 0 });
    for (const [off, col] of [["0", "#0a84ff"], [".55", "#5e5ce6"], [".85", "#bf5af2"], ["1", "#ff375f"]]) { const st = sv("stop", { offset: off }); st.style.stopColor = col; lg.append(st); }
    defs.append(lg);
    for (const [id, varName, top] of [[pre + "-iris", "--iris", 0.22], [pre + "-rose", "--rose", 0.26], [pre + "-cyan", "--cyan", 0.18], [pre + "-mint", "--mint", 0.2]]) {
      const g = sv("linearGradient", { id, x1: 0, y1: 0, x2: 0, y2: 1 });
      for (const [off, op] of [["0%", top], ["100%", 0.02]]) { const s = sv("stop", { offset: off }); s.style.stopColor = `var(${varName})`; s.style.stopOpacity = op; g.append(s); }
      defs.append(g);
    }
    svg.append(defs);
  }

  // ================================================================ TimeChart: tweened area/line chart
  class TimeChart {
    constructor(host, o) { this.host = host; this.o = o; this.vals = null; this.ymax = null; }
    build() {
      const W = this.host.clientWidth || 600, H = this.host.clientHeight || 190;
      if (this.svg && this.W === W && this.H === H) return;
      this.W = W; this.H = H;
      this.host.replaceChildren();
      const svg = sv("svg", { viewBox: `0 0 ${W} ${H}` });
      const pre = (this.host.id || "c") + "-g";
      gradients(svg, pre, W);
      this.gGrid = sv("g"); this.gData = sv("g"); this.gTop = sv("g");
      svg.append(this.gGrid, this.gData, this.gTop);
      this.areas = this.o.series.map((s) => s.area ? this.gData.appendChild(sv("path", { fill: `url(#${pre}-${s.color || "iris"})` })) : null);
      this.lines = this.o.series.map((s) => this.gData.appendChild(sv("path", { class: s.line })));
      this.lines.forEach((l, i) => { if (this.o.series[i].line === "ln-iris") l.style.stroke = `url(#${pre}-line)`; });
      this.xh = this.gTop.appendChild(sv("line", { class: "xh", visibility: "hidden" }));
      this.dots = this.o.series.map((s) => this.gTop.appendChild(sv("circle", { r: 3.5, class: "hdot", visibility: "hidden" })));
      this.dots.forEach((d, i) => { d.style.fill = `var(--${this.o.series[i].color || "iris"})`; });
      this.empty = this.gTop.appendChild(sv("text", { class: "empty", "text-anchor": "middle", x: W / 2, y: H / 2, visibility: "hidden" }));
      this.empty.textContent = this.o.empty || "No data in this window yet";
      if (this.o.nowDot) { this.ring = this.gTop.appendChild(sv("circle", { r: 7, class: "now-ring" })); this.dotNow = this.gTop.appendChild(sv("circle", { r: 3.5, class: "now-dot" })); }
      if (this.o.peak) this.peakTx = this.gTop.appendChild(sv("text", { class: "peak", "text-anchor": "middle" }));
      const hit = svg.appendChild(sv("rect", { fill: "transparent", x: 0, y: 0, width: W, height: H }));
      hit.addEventListener("mousemove", (ev) => this.hover(ev));
      hit.addEventListener("mouseleave", () => { this.xh.setAttribute("visibility", "hidden"); this.dots.forEach((d) => d.setAttribute("visibility", "hidden")); hideTip(); });
      this.host.append(svg);
      this.svg = svg;
      this.vals = null;
    }
    m() { return this.o.margin || { l: 32, r: 6, t: 8, b: 17 }; }
    targets() {
      const { series } = this.o;
      const raw = series.map((s) => this.pts.map((p) => p[s.k] == null ? null : +p[s.k]));
      if (this.o.stack) {
        const acc = this.pts.map(() => 0);
        return raw.map((arr) => arr.map((v, i) => (acc[i] += v || 0)));
      }
      return raw;
    }
    set(pts, dom) {
      this.build();
      this.pts = pts; this.dom = dom;
      const tgt = this.targets();
      let mx = 0;
      tgt.forEach((a) => a.forEach((v) => { if (v != null && v > mx) mx = v; }));
      const ymax = this.o.fixedMax || niceMax(mx * 1.1);
      const sameShape = this.vals && this.vals[0] && this.vals[0].length === tgt[0].length;
      const from = sameShape ? [...this.vals, this.ymax] : (this.o.grow === false ? null : [...tgt.map((a) => a.map((v) => v == null ? null : 0)), ymax]);
      this.empty.setAttribute("visibility", mx > 0 ? "hidden" : "visible");
      animateArrays(this, from, [...tgt, ymax], (v) => this.draw(v.slice(0, -1), v[v.length - 1]));
      this.vals = tgt; this.ymax = ymax;
    }
    x(i) { const m = this.m(); const [t0, t1] = this.dom; return m.l + (this.pts[i].t - t0) / ((t1 - t0) || 1) * (this.W - m.l - m.r); }
    y(v, ymax) { const m = this.m(); return this.H - m.b - v / ymax * (this.H - m.t - m.b); }
    draw(vals, ymax) {
      const m = this.m(), W = this.W, H = this.H, o = this.o;
      this.gGrid.replaceChildren();
      const ticks = o.ticks || 3;
      for (let i = 0; i <= ticks; i++) {
        const v = ymax * i / ticks, y = this.y(v, ymax);
        this.gGrid.append(sv("line", { x1: m.l, x2: W - m.r, y1: y, y2: y, class: "gl", "stroke-dasharray": i ? "2 5" : "" }));
        if (i) { const t = sv("text", { x: o.yRight ? W - m.r + 6 : m.l - 6, y: y + 3.5, class: "axis", "text-anchor": o.yRight ? "start" : "end" }); t.textContent = (o.fmtY || compact)(v); this.gGrid.append(t); }
      }
      const xl = o.xLabels ? o.xLabels(this.dom) : null;
      const [t0, t1] = this.dom;
      const nT = xl ? xl.length - 1 : Math.max(2, Math.min(6, Math.floor((W - m.l) / 100)));
      for (let i = 0; i <= nT; i++) {
        const t = xl ? xl[i][0] : t0 + (t1 - t0) * i / nT;
        const tx = sv("text", { x: m.l + (t - t0) / ((t1 - t0) || 1) * (W - m.l - m.r), y: H - 5, class: "axis", "text-anchor": i === 0 ? "start" : i === nT ? "end" : "middle" });
        tx.textContent = xl ? xl[i][1] : (o.fmtX || tclock)(t); this.gGrid.append(tx);
      }
      const base = this.y(0, ymax);
      const xs = this.pts.map((_, i) => this.x(i));
      vals.forEach((arr, s) => {
        const segs = [];
        let cur = [];
        arr.forEach((v, i) => { if (v == null) { if (cur.length) { segs.push(cur); cur = []; } } else cur.push(i); });
        if (cur.length) segs.push(cur);
        const mk = o.smooth ? (p) => smoothPath(p, base) : linePath;
        const pts = (idx, a) => idx.map((i) => [xs[i], this.y(a[i] || 0, ymax)]);
        this.lines[s].setAttribute("d", segs.map((idx) => mk(pts(idx, arr))).join(""));
        if (this.areas[s]) {
          const below = o.stack && s > 0 ? vals[s - 1] : null;
          let d = "";
          for (const idx of segs) {
            d += mk(pts(idx, arr));
            if (below) d += "L" + mk(pts([...idx].reverse(), below)).slice(1) + "Z";
            else d += `L${xs[idx[idx.length - 1]].toFixed(1)},${base}L${xs[idx[0]].toFixed(1)},${base}Z`;
          }
          this.areas[s].setAttribute("d", d);
        }
      });
      if (o.nowDot && this.pts.length) {
        const top = vals[vals.length - 1], i = top.length - 1, cx = this.x(i), cy = this.y(top[i] || 0, ymax);
        for (const c of [this.ring, this.dotNow]) { c.setAttribute("cx", cx); c.setAttribute("cy", cy); }
      }
      if (o.peak && this.pts.length) {
        const top = vals[vals.length - 1];
        let pi = 0; top.forEach((v, i) => { if ((v || 0) > (top[pi] || 0)) pi = i; });
        const pv = top[pi] || 0;
        this.peakTx.setAttribute("x", Math.max(m.l + 30, Math.min(W - m.r - 40, this.x(pi))));
        this.peakTx.setAttribute("y", this.y(pv, ymax) - 8);
        this.peakTx.textContent = pv > 0 ? o.peak(pv) : "";
      }
    }
    idxOfX(x) { let best = 0, bd = Infinity; for (let i = 0; i < this.pts.length; i++) { const d = Math.abs(this.x(i) - x); if (d < bd) { bd = d; best = i; } } return best; }
    hover(ev) {
      if (!this.pts || !this.pts.length) return;
      const r = this.svg.getBoundingClientRect();
      const i = this.idxOfX((ev.clientX - r.left) * (this.W / r.width));
      const x = this.x(i), m = this.m();
      this.xh.setAttribute("x1", x); this.xh.setAttribute("x2", x); this.xh.setAttribute("y1", m.t); this.xh.setAttribute("y2", this.H - m.b); this.xh.setAttribute("visibility", "visible");
      this.vals.forEach((arr, s) => {
        const v = arr[i];
        if (v == null) { this.dots[s].setAttribute("visibility", "hidden"); return; }
        this.dots[s].setAttribute("cx", x); this.dots[s].setAttribute("cy", this.y(v, this.ymax)); this.dots[s].setAttribute("visibility", "visible");
      });
      showTip(ev.clientX, ev.clientY, this.o.tip(this.pts[i]));
    }
  }

  // ================================================================ small widgets
  function spark(svgEl, vals) {
    if (!svgEl._l) { svgEl._a = svgEl.appendChild(sv("path", { class: "a" })); svgEl._l = svgEl.appendChild(sv("path", { class: "l" })); }
    const mx = Math.max(1, ...vals);
    const to = vals.map((v) => v / mx);
    const from = svgEl._v && svgEl._v.length === to.length ? svgEl._v : to.map(() => 0);
    svgEl._v = to;
    animateArrays(svgEl, [from], [to], ([a]) => {
      const n = a.length - 1 || 1;
      const p = a.map((v, i) => [i / n * 100, 23 - v * 21]);
      const d = linePath(p);
      svgEl._l.setAttribute("d", d);
      svgEl._a.setAttribute("d", d + `L100,24L0,24Z`);
    });
  }
  function barList(host, rows, opts = {}) {
    const fmt = opts.fmt || ((n) => nf.format(n));
    if (!rows.length) { host.replaceChildren(el("p", { class: "none" }, opts.empty || "Nothing yet")); host._nodes = null; return; }
    if (!host._nodes) { host.replaceChildren(); host._nodes = new Map(); }
    const nodes = host._nodes, max = Math.max(...rows.map((r) => r[1])), keep = new Set();
    rows.forEach(([name, n]) => {
      keep.add(name);
      let row = nodes.get(name);
      if (!row) {
        row = el("div", { class: "bar-row" + (opts.onClick ? " click" : ""), title: name });
        row._c = el("span", { class: "c" }); const tr = el("div", { class: "track" }); row._f = el("div", { class: "fill" }); tr.append(row._f);
        row.append(el("span", { class: "n" }, name), row._c, tr);
        if (opts.onClick) row.addEventListener("click", () => opts.onClick(name));
        nodes.set(name, row);
      }
      row._c.textContent = fmt(n);
      host.append(row);
      const w = Math.max(2, n / max * 100) + "%";
      requestAnimationFrame(() => requestAnimationFrame(() => { row._f.style.width = w; }));
    });
    for (const [k, row] of nodes) if (!keep.has(k)) { row.remove(); nodes.delete(k); }
  }
  const HLAB = ["0.5", "1", "5", "20", "50", "100", "300", "300+", "none"];
  const HFULL = ["under 0.5", "0.5–1", "1–5", "5–20", "20–50", "50–100", "100–300", "over 300", "none"];
  const HTONE = [0, 0, 1, 1, 2, 2, 3, 3, 4];
  function histogram(d) {
    const host = $("h-lat"), vals = [...d.counts, d.noresp];
    if (!host._cols) {
      host.replaceChildren(); host._cols = [];
      HLAB.forEach((lab, i) => {
        const col = el("div", { class: "hcol" }), v = el("div", { class: "hval" }), b = el("div", { class: "hbar", "data-tone": HTONE[i] });
        col.append(v, b, el("div", { class: "hlab" }, lab)); host.append(col);
        col.addEventListener("mousemove", (ev) => showTip(ev.clientX, ev.clientY, [{ t: lab === "none" ? "No reply within 10 s" : "Answered in " + HFULL[i] + " ms" }, { t: nf.format(col._n || 0) + " queries · " + ((100 * (col._n || 0) / (host._tot || 1)).toFixed(1)) + "%" }]));
        col.addEventListener("mouseleave", hideTip);
        host._cols.push({ col, v, b });
      });
    }
    const mx = Math.max(1, ...vals), tot = vals.reduce((a, b) => a + b, 0);
    host._tot = tot;
    vals.forEach((n, i) => { const c = host._cols[i]; c.col._n = n; c.v.textContent = n ? (n >= 1e6 ? (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + "M" : n >= 1e3 ? (n < 1e4 ? (n / 1e3).toFixed(1) : Math.round(n / 1e3)) + "K" : String(n)) : ""; const h = n / mx * 100; requestAnimationFrame(() => { c.b.style.height = `calc(${h}% - ${h ? 30 : 0}px)`; }); });
    const fast = d.counts.slice(0, 3).reduce((a, b) => a + b, 0);
    $("h-note").textContent = tot ? `ms, upper bound · ${(100 * fast / tot).toFixed(1)}% under 5 ms` : "ms, upper bound";
  }
  const RNAME = { NOERROR: "Answered", BLOCKED: "Blocked", NXDOMAIN: "Doesn't exist", SERVFAIL: "Server failure", NORESP: "No reply", REFUSED: "Refused", other: "Other" };
  const RORDER = ["NOERROR", "BLOCKED", "NXDOMAIN", "SERVFAIL", "NORESP", "REFUSED"];
  function donut(rcodes) {
    const svgEl = $("donut");
    const map = new Map(); let other = 0;
    for (const [k, n] of rcodes) { if (RORDER.includes(k)) map.set(k, n); else other += n; }
    if (other) map.set("other", other);
    const keys = [...RORDER, "other"].filter((k) => map.get(k));
    const tot = [...map.values()].reduce((a, b) => a + b, 0);
    const R = 46, C = 2 * Math.PI * R;
    if (!svgEl._init) {
      svgEl.replaceChildren(sv("circle", { cx: 60, cy: 60, r: R, class: "trk" }));
      svgEl._arcs = {};
      for (const k of [...RORDER, "other"]) {
        const c = sv("circle", { cx: 60, cy: 60, r: R, class: "t-" + k, "stroke-dasharray": `0 ${C}`, "stroke-dashoffset": 0 });
        c.addEventListener("mousemove", (ev) => showTip(ev.clientX, ev.clientY, [{ t: RNAME[k] }, { t: nf.format(c._n || 0) + " · " + (svgEl._tot ? (100 * (c._n || 0) / svgEl._tot).toFixed(1) : 0) + "%" }]));
        c.addEventListener("mouseleave", hideTip);
        svgEl.append(c); svgEl._arcs[k] = c;
      }
      const g = sv("g", { class: "donut-c" });
      svgEl._big = g.appendChild(sv("text", { x: 60, y: 62, class: "big" }));
      svgEl._sm = g.appendChild(sv("text", { x: 60, y: 76, class: "sm" }));
      svgEl._sm.textContent = "queries";
      svgEl.append(g); svgEl._init = true;
    }
    svgEl._tot = tot;
    let off = 0;
    for (const k of [...RORDER, "other"]) {
      const c = svgEl._arcs[k], n = map.get(k) || 0, len = tot ? C * n / tot : 0;
      c._n = n;
      const gap = len > 4 ? 2.5 : 0, at = off;
      requestAnimationFrame(() => { c.setAttribute("stroke-dasharray", `${Math.max(0, len - gap)} ${C}`); c.setAttribute("stroke-dashoffset", -at); });
      off += len;
    }
    svgEl._big.textContent = compact(tot);
    const ul = $("res-keys"); ul.replaceChildren();
    if (!tot) { ul.append(el("li", { class: "none" }, "No queries yet")); return; }
    for (const k of keys) {
      const li = el("li"); const b = el("b", {}, (100 * map.get(k) / tot).toFixed(1) + "%"); b.append(el("small", {}, compact(map.get(k))));
      li.append(el("i", { class: "t-" + k }), el("span", {}, RNAME[k]), b); ul.append(li);
    }
    $("res-total").textContent = "";
  }
  function forwarders(list) {
    const ul = $("t-up"); ul.replaceChildren();
    if (!list.length) { ul.append(el("li", { class: "none" }, "No upstream lookups in this window; everything came from cache.")); return; }
    for (const u of list.slice(0, 4)) {
      const tot = u.n + u.timeouts, loss = tot ? u.timeouts / tot : 0;
      const st = loss > 0.05 || (u.avg || 0) > 300 ? "bad" : loss > 0.01 || (u.avg || 0) > 100 ? "warn" : "";
      const rtt = el("span", { class: "rtt" }, u.avg == null ? "–" : u.avg < 10 ? u.avg.toFixed(1) : nf.format(Math.round(u.avg))); rtt.append(el("small", {}, " ms"));
      const li = el("li"); li.append(el("span", { class: "st " + st }), el("span", { class: "ip" }, u.server), rtt, el("span", { class: "meta" }, `${compact(u.n)} answers · ${compact(u.timeouts)} timeouts`));
      ul.append(li);
    }
  }

  // ================================================================ state + charts
  const state = { w: 3600, page: "overview", sub: "resolver", client: "", sortK: "n", sortD: -1, clients: [], lastLogTs: 0, logLoaded: false, settings: null, series: null };
  const winLabel = { 900: "15 minutes", 3600: "hour", 21600: "6 hours", 86400: "24 hours", 604800: "7 days", 2592000: "30 days", 7776000: "90 days" };
  const charts = {
    live: new TimeChart($("c-live"), { series: [{ k: "qps", line: "ln-iris", area: "ar-iris", color: "iris" }],
      smooth: true, nowDot: true, yRight: true, margin: { l: 4, r: 40, t: 16, b: 17 }, fmtY: (v) => (v >= 10 || Number.isInteger(v) ? Math.round(v) : v.toFixed(1)) + "/s",
      peak: (v) => `peak ${v.toFixed(1)}/s`, xLabels: ([a, b]) => [[a, "15 min ago"], [a + (b - a) / 2, "7 min ago"], [b, "now"]], empty: "Waiting for traffic",
      tip: (p) => [{ t: tsec(p.t) }, { sw: "iris", t: (p.qps || 0).toFixed(1) + " queries/s" }, { t: "avg answer " + ms(p.lat) }] }),
    qpm: new TimeChart($("c-qpm"), { series: [{ k: "qpm", line: "ln-iris", area: "ar-iris", color: "iris" }],
      tip: (p) => [{ t: tclock(p.t) + state.series.per }, { sw: "iris", t: compact(p.qpm) + " queries/min" }, { t: `${p.nx} not found · ${p.sf} failures` }] }),
    lat: new TimeChart($("c-lat"), { series: [{ k: "avg", line: "ln-iris", color: "iris" }, { k: "p95", line: "ln-cyan", color: "cyan" }], grow: true,
      fmtY: (v) => v < 1 ? v.toFixed(2) : v < 10 ? v.toFixed(1) : Math.round(v),
      tip: (p) => [{ t: tclock(p.t) }, { sw: "iris", t: "Average " + ms(p.avg) }, { sw: "cyan", t: "95th percentile " + ms(p.p95) }, { t: "Under 1 ms: " + pctf(p.fast) }] }),
    ddq: new TimeChart($("c-ddq"), { series: [{ k: "qps", line: "ln-iris", area: "ar-iris", color: "iris" }, { k: "fps", line: "ln-rose", color: "rose" }],
      smooth: true, grow: false, margin: { l: 32, r: 6, t: 8, b: 17 }, empty: "Collecting, one point every 2 seconds",
      fmtY: (v) => (v >= 10 || Number.isInteger(v) ? Math.round(v) : v.toFixed(1)), xLabels: ([a, b]) => [[a, "5 min ago"], [b, "now"]],
      tip: (p) => [{ t: tsec(p.t) }, { sw: "iris", t: p.qps.toFixed(1) + " queries/s" }, { sw: "rose", t: p.fps.toFixed(2) + " failures/s" }] }),
    ddc: new TimeChart($("c-ddc"), { series: [{ k: "hit", line: "ln-green", area: "ar-mint", color: "mint" }, { k: "cpu", line: "ln-amber", color: "amber" }],
      smooth: true, grow: false, fixedMax: 100, margin: { l: 32, r: 6, t: 8, b: 17 }, empty: "Collecting, one point every 2 seconds",
      fmtY: (v) => Math.round(v) + "%", xLabels: ([a, b]) => [[a, "5 min ago"], [b, "now"]],
      tip: (p) => [{ t: tsec(p.t) }, { sw: "green", t: "cache hits " + pctf(p.hit) }, { sw: "amber", t: "CPU " + pctf(p.cpu) }] }),
    blk: new TimeChart($("c-blk"), { series: [{ k: "bpm", line: "ln-rose", area: "ar-rose", color: "rose" }], smooth: true, empty: "Nothing blocked in this window",
      tip: (p) => [{ t: tclock(p.t) + state.series.per }, { sw: "rose", t: compact(p.bpm) + " blocked/min" }, { t: "of " + compact(p.qpm) + " queries/min" }] }),
  };

  // ================================================================ server stats
  const gb = (b) => b == null ? "–" : b >= 1e12 ? (b / 1e12).toFixed(1) + " TB" : (b / 1e9).toFixed(b >= 1e11 ? 0 : 1) + " GB";
  const mb = (b) => b == null ? "–" : b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : Math.round(b / 1e6) + " MB";
  function hs(id, text, pct, warn, bad, title) {
    const box = $(id);
    box.querySelector(".hs-v").textContent = text;
    const bar = box.querySelector(".hs-bar b");
    if (bar) bar.style.width = (pct == null ? 0 : Math.max(2, Math.min(100, pct))) + "%";
    box.classList.toggle("warn", pct != null && pct >= warn && pct < bad);
    box.classList.toggle("bad", pct != null && pct >= bad);
    if (title) box.title = title;
  }
  async function loadHost() {
    const h = await api("/api/host");
    hs("hs-cpu", h.cpu == null ? "–" : Math.round(h.cpu) + "%", h.cpu, 70, 90, `${h.cores} cores · load ${h.load ? h.load.map((x) => x.toFixed(2)).join(" / ") : "–"}`);
    hs("hs-ram", h.mem_pct == null ? "–" : Math.round(h.mem_pct) + "%", h.mem_pct, 80, 92, `${mb(h.mem_used)} of ${mb(h.mem_total)} in use`);
    const d = (h.disk && (h.disk.data || h.disk.root)) || null;
    const usedPct = d && d.total ? 100 * (1 - d.free / d.total) : null;
    hs("hs-disk", d ? gb(d.free) : "–", usedPct, 80, 92, d ? `${gb(d.free)} free of ${gb(d.total)}` : "");
    hs("hs-dd", h.dnsdist_rss == null ? "down" : mb(h.dnsdist_rss), null, 101, 101, "Memory used by dnsdist (mostly its answer cache)");
    $("hs-dd").classList.toggle("bad", h.dnsdist_rss == null);
    setLive(true, h.now);
  }

  // ================================================================ data loaders: overview
  async function loadLive() {
    const d = await api("/api/live");
    const end = Math.floor(d.now / 10) * 10 - 10, start = end - 890;
    const by = new Map(d.points.map((p) => [p.t, p]));
    const pts = [];
    for (let t = start; t <= end; t += 10) { const p = by.get(t) || { t, qps: 0, bps: 0, lat: null }; pts.push({ ...p, aps: Math.max(0, (p.qps || 0) - (p.bps || 0)) }); }
    charts.live.set(pts, [start, end]);
    $("t-lat").textContent = d.lat_now != null ? "answering in " + ms(d.lat_now) : "";
    setLive(true, d.now);
  }
  const WINW = { 900: "15 min", 3600: "hour", 21600: "6 hours", 86400: "24 hours", 604800: "7 days", 2592000: "30 days", 7776000: "90 days" };
  async function loadSummary() {
    const s = await api("/api/summary?w=" + state.w);
    state.summary = s;
    const per = (n, d) => d ? pctf(100 * n / d) : "–";
    const inWin = "in the last " + (WINW[state.w] || "window");
    tween($("k-queries"), s.queries, compact);
    $("k-queries-s").textContent = `${(s.qps_avg || 0).toFixed(1)}/s average`;
    tween($("k-hit"), s.hit_ratio, (v) => v.toFixed(1) + "%");
    $("k-hit-b").style.width = (s.hit_ratio || 0) + "%";
    $("k-avg").textContent = ms(s.avg_ms);
    $("k-avg-s").textContent = s.p50_ms == null ? inWin : "median " + ms(s.p50_ms);
    $("k-p95").textContent = ms(s.p95_ms);
    tween($("k-fast"), s.fast_pct, (v) => v.toFixed(1) + "%");
    $("k-fast-b").style.width = (s.fast_pct || 0) + "%";
    tween($("k-clients"), s.clients, compact);
    $("k-top").textContent = s.top_client ? `top ${s.top_client} ${per(s.top_client_n, s.queries)}` : inWin;
    $("k-peak").textContent = s.peak_qpm == null ? "–" : compact(s.peak_qpm) + "/min";
    $("k-peak-s").textContent = s.peak_at ? "at " + (state.w > 86400 ? tfull(s.peak_at) : tclock(s.peak_at)) : inWin;
    tween($("k-nx"), s.nx || 0, compact); $("k-nx-s").textContent = `${per(s.nx || 0, s.queries)} of queries`;
    const fails = (s.sf || 0) + (s.noresp || 0);
    tween($("k-sf"), fails, compact);
    tone($("k-sf"), s.queries ? (fails / s.queries > 0.02 ? "bad" : fails / s.queries > 0.005 ? "warn" : "good") : null);
    $("k-sf-s").textContent = `${compact(s.sf || 0)} failed · ${compact(s.noresp || 0)} unanswered`;
    tween($("k-local"), s.local || 0, compact); $("k-local-s").textContent = `${per(s.local || 0, s.queries)} of queries`;
    const up = s.upstream || [], un = up.reduce((a, u) => a + (u.n || 0), 0), uto = up.reduce((a, u) => a + (u.timeouts || 0), 0);
    const ulat = un ? up.reduce((a, u) => a + (u.avg || 0) * (u.n || 0), 0) / un : null;
    tween($("k-up"), un, compact); $("k-up-s").textContent = ulat == null ? "cache answered everything" : `average ${ms(ulat)} round trip`;
    tween($("k-to"), uto, compact); tone($("k-to"), un ? (uto / (un + uto) > 0.01 ? "warn" : "good") : null);
    $("k-to-s").textContent = `${per(uto, un + uto)} of upstream queries`;
    $("res-total").textContent = s.queries ? compact(s.queries) + " queries" : "";
    state.statsDays = s.stats_days; state.queryHours = s.query_hours;
  }
  async function loadSeries() {
    const d = await api("/api/series?w=" + state.w);
    const step = d.bucket_min * 60, now = Date.now() / 1000;
    const start = Math.floor((now - state.w) / step) * step, end = Math.floor(now / step) * step;
    const by = new Map(d.points.map((p) => [p.t, p]));
    const pts = [];
    for (let t = start; t <= end; t += step) { const p = by.get(t) || { t, n: 0, qpm: 0, avg: null, p95: null, nx: 0, sf: 0, fast: null, blk: 0, bpm: 0 }; pts.push({ ...p, apm: Math.max(0, p.qpm - (p.bpm || 0)) }); }
    state.series = { pts, start, end, per: d.bucket_min > 1 ? ` (${d.bucket_min}-min average)` : "" };
    if (state.page === "overview") {
      charts.qpm.set(pts, [start, end]); charts.lat.set(pts, [start, end]);
    }
    if (state.page === "blocking") charts.blk.set(pts, [start, end]);
  }
  async function loadLatency() { histogram(await api("/api/latency?w=" + state.w)); }
  async function loadTop() {
    const d = await api("/api/top?w=" + state.w + (state.client ? "&client=" + encodeURIComponent(state.client) : ""));
    state.top = d;
    if (state.page === "overview") {
      $("top-scope").textContent = state.client ? state.client : d.scope === "summary" ? "from hourly summaries" : "";
      const pick = (name) => { $("f-q").value = name; go("queries"); };
      barList($("t-names"), d.names.slice(0, 7), { onClick: pick, empty: "No queries yet" });
      barList($("t-nx"), (d.nxdomain || []).slice(0, 7).map((r) => [r[0], r[1]]), { onClick: pick, empty: "Every name resolved" });
      donut(d.rcodes);
      const chips = $("t-types"); chips.replaceChildren();
      for (const [t, n] of d.types.slice(0, 5)) { const c = el("span", { class: "chip" }); c.append(el("b", {}, t), document.createTextNode(compact(n))); chips.append(c); }
    }
    if (state.page === "blocking") blockingTop(d);
  }
  async function loadClients() {
    state.clients = await api("/api/clients?w=" + state.w);
    if (state.page === "overview") barList($("t-clients"), state.clients.slice(0, 7).map((c) => [c.client, c.n]), { onClick: (ip) => { setClient(ip); go("queries"); }, empty: "No clients yet" });
    if (state.page === "queries") renderClients();
  }

  // ================================================================ queries page
  function renderClients() {
    const tb = $("clients").tBodies[0]; tb.replaceChildren();
    const k = state.sortK, dir = state.sortD, ipn = (s) => s.split(".").reduce((a, o) => a * 256 + +o, 0);
    const rows = [...state.clients].sort((a, b) => ((k === "client" ? ipn(a.client) : (a[k] ?? -1)) - (k === "client" ? ipn(b.client) : (b[k] ?? -1))) * dir);
    if (!rows.length) { const tr = el("tr"); tr.append(el("td", { colspan: 4, class: "none" }, "No clients in this window")); tb.append(tr); return; }
    for (const c of rows) {
      const tr = el("tr", { class: c.client === state.client ? "sel" : null });
      tr.append(el("td", {}, c.client), el("td", { class: "r" }, nf.format(c.n)), el("td", { class: "r" }, nf.format(c.nx || 0)), el("td", { class: "r" }, ms(c.avg)));
      tr.addEventListener("click", () => setClient(c.client === state.client ? "" : c.client));
      tb.append(tr);
    }
  }
  document.querySelectorAll("#clients th[data-k]").forEach((th) => th.addEventListener("click", () => { const k = th.dataset.k; state.sortD = state.sortK === k ? -state.sortD : (k === "client" ? 1 : -1); state.sortK = k; renderClients(); }));
  function setClient(ip) { state.client = ip; $("f-client").value = ip; state.logLoaded = false; renderClients(); loadTop().catch(() => {}); loadLog().catch(() => {}); loadClient().catch(() => {}); }
  async function rule(domain, op, btn) {
    try { toast(await busy(btn, () => post("/api/rule", { domain, op }))); refreshPage(); }
    catch (e) { toast(e.message, true); }
  }
  let logBusy = false;
  async function loadLog() {
    if (logBusy) return; logBusy = true;
    try {
      const p = new URLSearchParams({ w: state.w, limit: 300 });
      const c = $("f-client").value.trim(), q = $("f-q").value.trim(), rc = $("f-rcode").value;
      if (c) p.set("client", c); if (q) p.set("q", q); if (rc) p.set("rcode", rc); if ($("f-slow").checked) p.set("slow", "1");
      const rows = await api("/api/log?" + p.toString());
      const tb = $("log").tBodies[0]; tb.replaceChildren();
      const prev = state.lastLogTs;
      for (const r of rows) {
        const tr = el("tr", { class: state.logLoaded && r.ts > prev ? "fresh" : null });
        const latCls = r.lat == null ? "" : r.lat < 1 ? "lat-fast" : r.lat >= 100 ? "lat-bad" : r.lat >= 20 ? "lat-slow" : "";
        const res = el("td"); res.append(el("span", { class: "rc rc-" + r.rcode, title: r.pol ? (r.pol === "list" ? "Blocked by a downloaded list" : "Blocked by your own rule") : RNAME[r.rcode] || r.rcode }, r.rcode));
        const cl = el("td", { class: "cl", title: "Focus on this client" }, r.client); cl.addEventListener("click", () => setClient(r.client));
        const act = el("td", { class: "r" });
        const b = el("button", { class: "btn ghost xs act", type: "button" }, r.rcode === "BLOCKED" ? "Allow" : "Block");
        b.addEventListener("click", (ev) => { ev.stopPropagation(); rule(r.qname, r.rcode === "BLOCKED" ? "allow" : "block", b); });
        act.append(b);
        tr.append(el("td", {}, tsec(r.ts)), cl, el("td", { class: "name" }, r.qname), el("td", {}, r.qtype), res, el("td", { class: "r " + latCls }, r.lat == null ? "no reply" : ms(r.lat)), act);
        tb.append(tr);
      }
      if (rows.length) state.lastLogTs = Math.max(prev, rows[0].ts);
      state.logLoaded = true;
      const span = state.queryHours && state.w > state.queryHours * 3600 ? `Individual queries are kept for ${state.queryHours >= 48 ? state.queryHours / 24 + " days" : state.queryHours + " hours"} (change in Settings › Data & logs). ` : "";
      $("log-note").textContent = span + (rows.length >= 300 ? "Newest 300 matching queries. Narrow the filters to reach older ones." : rows.length ? `${rows.length} matching queries.` : "No queries match these filters.");
    } finally { logBusy = false; }
  }
  let deb;
  ["f-client", "f-q"].forEach((id) => $(id).addEventListener("input", () => { clearTimeout(deb); deb = setTimeout(() => { state.logLoaded = false; if (id === "f-client") { state.client = $("f-client").value.trim(); renderClients(); } loadLog().catch(() => {}); }, 350); }));
  ["f-rcode", "f-slow"].forEach((id) => $(id).addEventListener("change", () => { state.logLoaded = false; loadLog().catch(() => {}); }));
  $("f-clear").addEventListener("click", () => { $("f-q").value = ""; $("f-rcode").value = ""; $("f-slow").checked = false; setClient(""); });

  // ================================================================ blocking page
  async function loadSettingsDoc() { state.settings = await api("/api/settings"); return state.settings; }
  function blockingSummary(s) {
    tween($("bk-n"), s.blocked, compact);
    $("bk-pct").textContent = s.blocked_pct == null ? "–" : `${s.blocked_pct.toFixed(1)}% of all queries`;
    tween($("bk-clients"), s.blocked_clients, compact);
  }
  function blockingTop(d) {
    const host = $("bk-top"); host.replaceChildren();
    if (!d.blocked.length) host.append(el("p", { class: "none" }, "Nothing blocked in this window."));
    for (const [name, n, pol] of d.blocked.slice(0, 12)) {
      const row = el("div", { class: "brow" }), nm = el("span", { class: "n", title: name }, name);
      nm.append(el("span", { class: "src" }, pol === "list" ? "list" : "your rule"));
      const b = el("button", { class: "btn ghost xs", type: "button" }, "Allow");
      b.addEventListener("click", () => rule(name, "allow", b));
      row.append(nm, el("span", { class: "c" }, nf.format(n)), b); host.append(row);
    }
    barList($("bk-clients-top"), d.blocked_clients, { empty: "No clients blocked" });
  }
  async function loadBlockedLog() {
    const rows = await api(`/api/log?w=${state.w}&rcode=BLOCKED&limit=60`);
    const tb = $("bk-log").tBodies[0]; tb.replaceChildren();
    if (!rows.length) { const tr = el("tr"); tr.append(el("td", { class: "none" }, "Nothing blocked yet")); tb.append(tr); }
    for (const r of rows) { const tr = el("tr"); tr.append(el("td", {}, tsec(r.ts)), el("td", {}, r.client), el("td", { class: "name" }, r.qname)); tb.append(tr); }
  }
  async function loadBlockingState() {
    const doc = await loadSettingsDoc();
    const b = doc.settings.blocking, total = (doc.lists._total || {});
    const on = b.enabled, nLists = b.lists.filter((l) => l.enabled).length;
    $("blk-banner").classList.toggle("off", !on);
    $("blk-state").textContent = on ? "Blocking is on" : "Blocking is off";
    $("blk-sub").textContent = on ? `${compact(total.count || 0)} domains from ${nLists} list${nLists === 1 ? "" : "s"}, plus ${b.block.length} of your own. ${total.updated ? "Lists updated " + ago(total.updated) + "." : "Lists not downloaded yet."}`
      : "Turn it on in Settings › Blocklists, or block a single domain here.";
    tween($("bk-domains"), total.count || 0, compact);
    $("bk-lists").textContent = `${nLists} of ${b.lists.length} lists enabled`;
    $("bk-rules").textContent = `${b.block.length} / ${b.allow.length}`;
    $("bk-rules-s").textContent = "blocked / always allowed";
  }
  $("quick").addEventListener("submit", (ev) => { ev.preventDefault(); const d = $("quick-domain").value.trim(); if (d) rule(d, "block", ev.submitter).then(() => { $("quick-domain").value = ""; loadBlockingState().catch(() => {}); }); });
  $("quick-allow").addEventListener("click", (ev) => { const d = $("quick-domain").value.trim(); if (d) rule(d, "allow", ev.currentTarget).then(() => { $("quick-domain").value = ""; loadBlockingState().catch(() => {}); }); });

  // ================================================================ settings
  const lines = (s) => s.split(/[\n,]+/).map((x) => x.trim()).filter(Boolean);
  function fillResolver() {
    const f = $("s-resolver"), r = state.settings.settings.resolver;
    f.forwarders.value = r.forwarders.join("\n"); f.policy.value = r.policy || "leastOutstanding";
    f.apple_to_bind.checked = r.apple_to_bind !== false; f.local_suffixes.value = (r.local_suffixes || []).join("\n");
    $("bind-zone").textContent = state.settings.settings.local.zone;
    f.query_acl.value = r.query_acl.join("\n");
    f.cache_entries.value = r.cache_entries; f.max_cache_ttl.value = r.max_cache_ttl; f.max_ncache_ttl.value = r.max_ncache_ttl;
    f.serve_stale.checked = !!r.serve_stale;
    f.rl_enabled.checked = !!r.rate_limit.enabled; f.rl_qps.value = r.rate_limit.qps; f.rl_exempt.value = r.rate_limit.exempt.join("\n");
    const box = $("listen-checks"); box.replaceChildren();
    const all = r.listen.includes("any");
    const allLab = el("label", { class: "all-ifaces" });
    const allCb = el("input", { type: "checkbox", value: "any", checked: all, id: "listen-all" });
    allLab.append(allCb, document.createTextNode("All interfaces")); box.append(allLab);
    const per = [];
    for (const ip of state.settings.host_ips) {
      const lab = el("label"); const cb = el("input", { type: "checkbox", value: ip, checked: all || r.listen.includes(ip), disabled: all || ip === "127.0.0.1" });
      lab.append(cb, document.createTextNode(ip)); box.append(lab); per.push(cb);
    }
    allCb.addEventListener("change", () => {
      for (const cb of per) { cb.disabled = allCb.checked || cb.value === "127.0.0.1"; if (allCb.checked) cb.checked = true; }
    });
  }
  function collectResolver() {
    const f = $("s-resolver");
    return { forwarders: lines(f.forwarders.value), policy: f.policy.value, apple_to_bind: f.apple_to_bind.checked, local_suffixes: lines(f.local_suffixes.value),
      query_acl: lines(f.query_acl.value),
      listen: $("listen-all").checked ? ["any"] : [...$("listen-checks").querySelectorAll("input:checked")].map((c) => c.value),
      cache_entries: +f.cache_entries.value, max_cache_ttl: +f.max_cache_ttl.value, max_ncache_ttl: +f.max_ncache_ttl.value, serve_stale: f.serve_stale.checked,
      rate_limit: { enabled: f.rl_enabled.checked, qps: +f.rl_qps.value, exempt: lines(f.rl_exempt.value) } };
  }
  let workLists = [];
  function fillBlocklists() {
    const f = $("s-blocklists"), b = state.settings.settings.blocking;
    f.b_enabled.checked = b.enabled; f.b_action.value = b.action;
    f.b_auto.value = [0, 6, 12, 24, 72, 168].includes(b.auto_update_hours) ? String(b.auto_update_hours) : "24";
    f.b_block.value = b.block.join("\n"); f.b_allow.value = b.allow.join("\n");
    workLists = b.lists.map((l) => ({ ...l }));
    renderLists(); jobNote(state.settings.job);
  }
  function renderLists() {
    const tb = $("lists-body"); tb.replaceChildren();
    const st = state.settings.lists || {};
    workLists.forEach((l, i) => {
      const s = st[l.id] || {};
      const tr = el("tr");
      const on = el("input", { type: "checkbox", checked: l.enabled, "aria-label": "Enable " + l.name }); on.addEventListener("change", () => { l.enabled = on.checked; });
      const wc = el("input", { type: "checkbox", checked: l.wildcard, "aria-label": "Block subdomains" }); wc.addEventListener("change", () => { l.wildcard = wc.checked; });
      const name = el("input", { value: l.name, "aria-label": "List name" }); name.addEventListener("input", () => { l.name = name.value; });
      const rm = el("button", { class: "btn ghost xs", type: "button" }, "Remove"); rm.addEventListener("click", () => { workLists.splice(i, 1); renderLists(); });
      const upd = el("td"); if (s.error) upd.append(el("span", { class: "err", title: s.error }, "Failed: " + s.error.slice(0, 60))); else upd.textContent = s.updated ? ago(s.updated) : "never";
      const c1 = el("td"); c1.append(on); const c4 = el("td"); c4.append(wc); const c2 = el("td"); c2.append(name); const c7 = el("td", { class: "r" }); c7.append(rm);
      tr.append(c1, c2, el("td", { class: "url" }, l.url), c4, el("td", { class: "r", title: s.skipped ? `${nf.format(s.skipped)} browser-only rules (paths, $third-party, cosmetic) were ignored` : "" }, s.count ? nf.format(s.count) + (s.skipped ? ` (+${compact(s.skipped)} ignored)` : "") : "–"), upd, c7);
      tb.append(tr);
    });
  }
  $("nl-add").addEventListener("click", () => {
    const name = $("nl-name").value.trim(), url = $("nl-url").value.trim();
    if (!/^https?:\/\/\S+$/.test(url)) { toast("Enter the list's full http(s) address", true); return; }
    workLists.push({ id: "", name: name || url.split("/").pop() || "Custom list", url, enabled: true, wildcard: true });
    $("nl-name").value = ""; $("nl-url").value = ""; renderLists();
  });
  function collectBlocking() {
    const f = $("s-blocklists");
    return { enabled: f.b_enabled.checked, action: f.b_action.value, auto_update_hours: +f.b_auto.value, lists: workLists, block: lines(f.b_block.value), allow: lines(f.b_allow.value) };
  }
  function jobNote(job) {
    const n = $("job-note");
    if (!job) { n.textContent = ""; return; }
    if (job.running) n.textContent = "Updating lists: " + job.message;
    else if (job.finished) n.textContent = (job.ok ? "Last update: " : "Last update failed: ") + job.message;
    else n.textContent = "";
  }
  let jobTimer = null;
  function watchJob() {
    clearInterval(jobTimer);
    jobTimer = setInterval(async () => {
      try {
        const st = await api("/api/status");
        jobNote(st.job);
        if (!st.job.running) {
          clearInterval(jobTimer);
          toast(st.job.message, st.job.ok === false);
          await loadSettingsDoc(); if (state.sub === "blocklists") renderLists();
        }
      } catch (e) { clearInterval(jobTimer); }
    }, 2000);
  }
  $("lists-update").addEventListener("click", async (ev) => {
    try { toast(await busy(ev.currentTarget, () => post("/api/lists/update", {}))); watchJob(); } catch (e) { toast(e.message, true); }
  });
  let workRecs = [];
  function fillRecords() {
    const l = state.settings.settings.local;
    $("s-records").zone.value = l.zone;
    workRecs = l.records.map((r) => ({ ...r }));
    renderRecs();
  }
  function renderRecs() {
    const tb = $("recs-body"); tb.replaceChildren();
    workRecs.forEach((r, i) => {
      const tr = el("tr");
      const name = el("input", { value: r.name, "aria-label": "Name", spellcheck: "false" }); name.addEventListener("input", () => { r.name = name.value; });
      const type = el("select", { "aria-label": "Type" }); for (const t of ["A", "AAAA", "CNAME", "TXT"]) type.append(el("option", { selected: r.type === t }, t)); type.addEventListener("change", () => { r.type = type.value; });
      const val = el("input", { value: r.value, "aria-label": "Value", spellcheck: "false" }); val.addEventListener("input", () => { r.value = val.value; });
      const ttl = el("input", { value: r.ttl || "", placeholder: "default", "aria-label": "TTL", type: "number" }); ttl.addEventListener("input", () => { r.ttl = ttl.value ? +ttl.value : null; });
      const rm = el("button", { class: "btn ghost xs", type: "button" }, "Delete"); rm.addEventListener("click", () => { workRecs.splice(i, 1); renderRecs(); });
      for (const x of [name, type, val, ttl]) { const td = el("td"); td.append(x); tr.append(td); }
      const td = el("td", { class: "r" }); td.append(rm); tr.append(td); tb.append(tr);
    });
  }
  $("rec-add").addEventListener("click", () => { workRecs.push({ name: "", type: "A", value: "", ttl: null }); renderRecs(); const inputs = $("recs-body").querySelectorAll("input"); inputs[inputs.length - 3].focus(); });
  async function saveSettings(patch, btn) {
    const cur = state.settings.settings;
    const body = { resolver: cur.resolver, local: cur.local, blocking: cur.blocking, data: cur.data, ...patch };
    try {
      const msg = await busy(btn, () => post("/api/settings", { settings: body }));
      toast(msg);
      await loadSettingsDoc(); fillSub(state.sub);
      if (/background/.test(msg)) watchJob();
    } catch (e) { toast(e.message, true); }
  }
  $("s-resolver").addEventListener("submit", (ev) => { ev.preventDefault(); saveSettings({ resolver: collectResolver() }, ev.submitter); });
  $("s-blocklists").addEventListener("submit", (ev) => { ev.preventDefault(); saveSettings({ blocking: collectBlocking() }, ev.submitter); });
  $("s-records").addEventListener("submit", (ev) => { ev.preventDefault(); saveSettings({ local: { zone: $("s-records").zone.value.trim(), records: workRecs.filter((r) => r.name.trim() || r.value.trim()) } }, ev.submitter); });
  $("s-account").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const f = ev.currentTarget;
    if (f.password.value !== f.password2.value) { toast("The new passwords don't match", true); return; }
    try { toast(await busy(ev.submitter, () => post("/api/account", { user: f.user.value.trim(), current: f.current.value, password: f.password.value }))); f.current.value = f.password.value = f.password2.value = ""; }
    catch (e) { toast(e.message, true); }
  });
  async function fillData() {
    const f = $("s-data"), d = state.settings.settings.data || {};
    for (const k of ["query_hours", "stats_days", "audit_days", "bind_log_versions", "bind_log_size_mb"]) if (d[k] != null) f[k].value = String(d[k]);
    await loadDbFacts();
  }
  async function loadDbFacts() {
    const i = await api("/api/data");
    const dl = $("db-facts"); dl.replaceChildren();
    for (const [k, v] of [["Database size", mb(i.db_bytes)], ["Queries stored", nf.format(i.queries)],
      ["Oldest query", i.oldest_query ? tfull(i.oldest_query) : "–"], ["Statistics since", i.oldest_stats ? tfull(i.oldest_stats) : "–"]]) dl.append(el("dt", {}, k), el("dd", {}, v));
  }
  $("s-data").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const f = ev.currentTarget;
    saveSettings({ data: { query_hours: +f.query_hours.value, stats_days: +f.stats_days.value, audit_days: +f.audit_days.value,
      bind_log_versions: +f.bind_log_versions.value, bind_log_size_mb: +f.bind_log_size_mb.value } }, ev.submitter);
  });
  $("db-compact").addEventListener("click", async (ev) => {
    try { toast(await busy(ev.currentTarget, () => post("/api/data/compact", {}))); loadDbFacts().catch(() => {}); } catch (e) { toast(e.message, true); }
  });
  $("db-clear").addEventListener("click", async (ev) => {
    const btn = ev.currentTarget;
    if (!(await confirmBox("Delete every stored individual query? Statistics and hourly summaries are kept. This cannot be undone.", "Delete"))) return;
    try { toast(await busy(btn, () => post("/api/data/clear", {}))); loadDbFacts().catch(() => {}); } catch (e) { toast(e.message, true); }
  });
  function svcState(prefix, name, active, version, since) {
    const ok = active === "active";
    $(prefix + "dot").className = "state-dot " + (ok ? "ok" : "bad");
    $(prefix + "title").textContent = ok ? `${name} is running` : `${name} is ${active || "not running"}`;
    $(prefix + "sub").textContent = [version, since ? "since " + since : ""].filter(Boolean).join(" · ");
  }
  $("db-reset").addEventListener("click", async (ev) => {
    const btn = ev.currentTarget;
    if (!(await confirmBox("Delete all history and statistics: every stored query, the per-minute statistics and the hourly summaries? Charts start again from now. dnsdist and BIND counters are not affected. This cannot be undone.", "Delete everything"))) return;
    try { toast(await busy(btn, () => post("/api/data/reset", {}))); loadDbFacts().catch(() => {}); } catch (e) { toast(e.message, true); }
  });
  async function loadService() {
    const st = await api("/api/status");
    const dd = st.dnsdist || {};
    svcState("svc-dd-", "dnsdist", dd.active, dd.version, dd.since);
    svcState("svc-", "BIND", st.active, st.version, st.since);
    $("svc-rndc").textContent = st.rndc || "–";
    const ddl = $("svc-ddlog"); ddl.textContent = (dd.log || []).join("\n") || "–"; ddl.scrollTop = ddl.scrollHeight;
    const log = $("svc-log"); log.textContent = (st.log || []).join("\n"); log.scrollTop = log.scrollHeight;
  }
  const CONFIRM = {
    restart: ["Restart BIND? Local names and Apple content caching lookups stop answering for a few seconds.", "Restart BIND"],
    dd_restart: ["Restart dnsdist? DNS stops answering for under a second and the answer cache starts empty.", "Restart dnsdist"],
    flush: ["Empty the dnsdist and BIND caches? Lookups are slower for a few minutes while they refill.", "Flush caches"],
  };
  document.querySelectorAll(".svc-actions [data-act]").forEach((b) => b.addEventListener("click", async () => {
    const act = b.dataset.act;
    if (CONFIRM[act] && !(await confirmBox(...CONFIRM[act]))) return;
    try { toast(await busy(b, () => post("/api/service", { action: act }))); loadService().catch(() => {}); } catch (e) { toast(e.message, true); }
  }));
  $("flushname").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    try { toast(await busy(ev.submitter, () => post("/api/service", { action: "flushname", name: $("fn-domain").value.trim() }))); $("fn-domain").value = ""; } catch (e) { toast(e.message, true); }
  });
  async function loadAudit() {
    const rows = await api("/api/audit");
    const tb = $("audit-body"); tb.replaceChildren();
    if (!rows.length) { const tr = el("tr"); tr.append(el("td", { colspan: 5, class: "none" }, "No changes recorded yet")); tb.append(tr); }
    const what = { settings: "Settings saved", rule: "Domain rule", service: "Service action", lists_update: "Blocklists updated", password: "Login changed" };
    for (const a of rows) { const tr = el("tr"); tr.append(el("td", {}, tfull(a.ts)), el("td", {}, a.user), el("td", {}, a.ip), el("td", {}, what[a.action] || a.action), el("td", { class: "name" }, a.detail)); tb.append(tr); }
  }
  async function fillSub(sub) {
    document.querySelectorAll(".subnav a").forEach((a) => a.classList.toggle("on", a.dataset.sub === sub));
    document.querySelectorAll(".set[data-sub]").forEach((f) => { f.hidden = f.dataset.sub !== sub; });
    try {
      if (["resolver", "blocklists", "records", "data"].includes(sub)) {
        if (!state.settings) await loadSettingsDoc();
        await ({ resolver: fillResolver, blocklists: fillBlocklists, records: fillRecords, data: fillData })[sub]();
      } else if (sub === "service") await loadService();
      else if (sub === "account") { $("s-account").user.value = state.user || ""; }
      else if (sub === "activity") await loadAudit();
    } catch (e) { toast(e.message, true); }
  }

  // ================================================================ dnsdist page
  const dur = (s) => s == null ? "–" : s < 3600 ? Math.round(s / 60) + " min" : s < 172800 ? (s / 3600).toFixed(1) + " h" : Math.round(s / 86400) + " days";
  const POLICY = { leastOutstanding: "fewest waiting", firstAvailable: "first healthy", roundrobin: "round robin", wrandom: "random", chashed: "consistent hash", whashed: "hashed" };
  let ddPrev = null;
  const ddHist = [];
  const per = (n, d) => d ? pctf(100 * n / d) : "–";
  async function loadDnsdist() {
    const d = await api("/api/dnsdist");
    $("dd-down").hidden = d.ok;
    if (!d.ok) { $("dd-down").textContent = d.error + ". Check Settings › Service."; return; }
    const st = d.stats, now = d.now, q = st.queries || 0;
    const cpuMs = (st["cpu-user-msec"] || 0) + (st["cpu-sys-msec"] || 0);
    const fails = (st["frontend-servfail"] || 0);
    const hist = d.hist || [];
    if (hist.length) {
      tween($("dd-qps"), hist[hist.length - 1].qps, (v) => v >= 100 ? nf.format(Math.round(v)) : v.toFixed(1));
      charts.ddq.set(hist, [now - 300, now]); charts.ddc.set(hist, [now - 300, now]);
    }
    const pool = d.pools.find((p) => p.name === "") || {}, lpool = d.pools.find((p) => p.name === "bind") || {};
    tween($("dd-cache"), (pool.cacheEntries || 0) + (lpool.cacheEntries || 0), compact);
    $("dd-cache-s").textContent = pool.cacheSize ? `right now · ${pctf(100 * (pool.cacheEntries || 0) / pool.cacheSize)} of ${compact(pool.cacheSize)}` : "right now";
    const lb = [["Under 1 ms", st["latency0-1"]], ["1–10 ms", st["latency1-10"]], ["10–50 ms", st["latency10-50"]], ["50–100 ms", st["latency50-100"]],
      ["100 ms–1 s", st["latency100-1000"]], ["Over 1 s", st["latency-slow"]]].map(([k, v]) => [k, v || 0]);
    const ltot = lb.reduce((a, r) => a + r[1], 0);
    barList($("dd-lat-bars"), ltot ? lb : [], { fmt: (n) => `${pctf(100 * n / ltot)} · ${compact(n)}`, empty: "No answers yet" });
    const inet = d.servers.filter((v) => !(v.pools || []).includes("bind"));
    const upN = inet.filter((v) => String(v.state).toLowerCase() === "up").length;
    $("dd-ups").textContent = `${upN} of ${inet.length} up`;
    tone($("dd-ups"), upN === inet.length ? "good" : upN ? "warn" : "bad");
    const fastest = inet.filter((v) => v.latency).sort((a, b) => a.latency - b.latency)[0];
    $("dd-ups-s").textContent = fastest ? `right now · fastest ${ms(fastest.latency)}` : "right now";
    $("dd-up").textContent = dur(st.uptime);
    $("dd-ver").textContent = `dnsdist ${(d.version || "").split(" ")[0]} · ${mb(st["real-memory-usage"])}`;
    $("dd-policy").textContent = d.server_policy ? `chosen by ${POLICY[d.server_policy] || d.server_policy} · ` : "";
    const tb = $("dd-servers").tBodies[0]; tb.replaceChildren();
    for (const v of d.servers) {
      const up = String(v.state).toLowerCase() === "up";
      const local = (v.pools || []).includes("bind");
      const tr = el("tr");
      const stc = el("td"); stc.append(el("span", { class: "rc " + (up ? "rc-NOERROR" : "rc-SERVFAIL") }, up ? "up" : String(v.state).toLowerCase()));
      tr.append(el("td", { title: v.address }, local ? "BIND " + v.address : v.name), el("td", {}, local ? "Local, Apple caching" : "Internet"), stc,
        el("td", { class: "r" }, (v.qps || 0).toFixed(1)), el("td", { class: "r" }, v.latency ? ms(v.latency) : "–"),
        el("td", { class: "r" }, compact(v.queries || 0)), el("td", { class: "r" }, nf.format(v.outstanding || 0)), el("td", { class: "r" }, pctf(v.dropRate || 0)));
      tb.append(tr);
    }
    const rb = $("dd-rules").tBodies[0]; rb.replaceChildren();
    const desc = (r) => /qname==in-set|SuffixMatch|qname in/i.test(r) ? "Local zone, private reverse" : /aaplcache/.test(r) ? "Apple content caching" : /MaxQPSIP|qps/i.test(r) ? "Clients over the rate limit" : r;
    const dest = (a) => /pool bind/.test(a) ? "BIND" : /tc|truncat/i.test(a) ? "Retry over TCP" : a;
    for (const r of d.rules) { const tr = el("tr"); tr.append(el("td", { title: r.rule }, desc(r.rule)), el("td", {}, dest(r.action)), el("td", { class: "r" }, compact(r.matches))); rb.append(tr); }
    const tr = el("tr"); tr.append(el("td", {}, "Everything else"), el("td", {}, "Upstreams"), el("td", { class: "r" }, compact(Math.max(0, q - d.rules.reduce((a, r) => a + (r.matches || 0), 0))))); rb.append(tr);
    const hl = $("dd-health"); hl.replaceChildren();
    for (const [k, v, warn] of [
      ["Refused by access list", compact(st["acl-drops"] || 0), st["acl-drops"] > 0],
      ["Kernel receive drops", compact(st["udp-recvbuf-errors"] || 0), st["udp-recvbuf-errors"] > 0],
      ["Upstream send errors", compact(st["downstream-send-errors"] || 0), st["downstream-send-errors"] > 0],
      ["Truncated (retry over TCP)", compact(st["rule-truncated"] || 0)],
      ["CPU time", dur(cpuMs / 1000)], ["Open files", compact(st["fd-usage"] || 0)]]) {
      hl.append(el("dt", {}, k), el("dd", { class: warn ? "warn" : null }, v));
    }
  }
  async function loadBind() {
    const b = await api("/api/bind");
    if (!b.ok) { $("b-status").textContent = b.error; return; }
    const ns = b.ns, q = b.queries || 0;
    const ago = (iso) => iso ? (Date.now() - Date.parse(iso)) / 1000 : null;
    $("b-status").textContent = "local zones and Apple content caching, behind dnsdist";
    tween($("b-q"), q, compact);
    $("b-q-s").textContent = `${compact(ns.QryUDP)} UDP · ${compact(ns.QryTCP)} TCP`;
    tween($("b-auth"), ns.QryAuthAns || 0, compact); $("b-auth-s").textContent = `${per(ns.QryAuthAns || 0, q)} of its queries`;
    tween($("b-nx"), ns.QryNXDOMAIN || 0, compact); $("b-nx-s").textContent = `${per(ns.QryNXDOMAIN || 0, q)} · ${compact(ns.QryNxrrset || 0)} no such record type`;
    const bf = (ns.QrySERVFAIL || 0) + (ns.QryFailure || 0);
    tween($("b-sf"), bf, compact); tone($("b-sf"), bf ? "warn" : "good"); $("b-sf-s").textContent = `${compact(ns.QryDropped || 0)} dropped`;
    tween($("b-fwd"), b.forwarded || 0, compact); $("b-fwd-s").textContent = `${compact(b.fwd_timeouts || 0)} timeouts · names outside its zones`;
    $("b-up").textContent = dur(ago(b.boot));
    $("b-ver").textContent = `BIND ${(b.version || "").split("-")[0]} · ${mb(b.rss)}`;
  }

  // ================================================================ client details
  async function loadClient() {
    const ip = state.client;
    $("cc-empty").hidden = !!ip; $("cc-body").hidden = !ip; $("cc-close").hidden = !ip;
    if (!ip) return;
    const c = await api("/api/client?w=" + state.w + "&ip=" + encodeURIComponent(ip));
    if (c.client !== state.client) return;
    $("cc-ip").textContent = c.client;
    $("cc-host").textContent = c.hostname || "No hostname registered";
    const hints = $("cc-hints"); hints.replaceChildren();
    for (const [label] of c.hints) hints.append(el("span", { class: "chip hint-chip" }, label));
    if (!c.hints.length) hints.append(el("span", { class: "chip" }, "Device type unknown"));
    const f = $("cc-facts"); f.replaceChildren();
    const rows = [
      ["Hardware address", c.arp ? c.arp.mac + (c.arp.private ? " (private Wi-Fi address)" : "") : "Not on a network this server is attached to"],
      ["Seen on", c.arp ? c.arp.dev : "through a router"],
      ["Queries in this window", nf.format(c.queries)], ["Doesn't exist", `${nf.format(c.nx)} · ${per(c.nx, c.queries)}`],
      ["Failed", nf.format(c.failed)], ["Average answer", ms(c.avg)],
      ["Last query", c.last ? tsec(c.last) : "–"], ["First seen", c.first_seen ? tfull(c.first_seen) : "–"]];
    for (const [k, v] of rows) f.append(el("dt", {}, k), el("dd", {}, v));
    const act = $("cc-act"); act.replaceChildren();
    const mx = Math.max(1, ...c.activity);
    c.activity.forEach((n, i) => {
      const b = el("i", { title: `${n} queries` });
      b.style.height = Math.max(4, 100 * n / mx) + "%";
      act.append(b);
    });
    barList($("cc-names"), c.names.slice(0, 8), { empty: "No queries in this window" });
  }
  $("cc-close").addEventListener("click", () => setClient(""));

  // ================================================================ router + refresh
  const TITLES = { overview: "Overview", queries: "Queries", settings: "Settings" };
  function go(page) { location.hash = "#/" + page; }
  function route() {
    const [, page = "overview", sub] = location.hash.split("/");
    state.page = TITLES[page] ? page : "overview";
    document.querySelectorAll(".rail a[data-page]").forEach((a) => a.classList.toggle("on", a.dataset.page === state.page));
    for (const p of [...Object.keys(TITLES), "blocking"]) $("p-" + p).hidden = p !== state.page;
    $("page-title").textContent = TITLES[state.page];
    $("range").hidden = state.page === "settings";
    if (state.page === "settings") { state.sub = sub || state.sub || "resolver"; state.settings = null; fillSub(state.sub); }
    else { Object.values(charts).forEach((c) => { c.svg = null; }); refreshPage(true); }
    window.scrollTo(0, 0);
  }
  window.addEventListener("hashchange", route);
  function setWindow(w) {
    state.w = w; state.logLoaded = false;
    const long = w > 86400;
    document.querySelectorAll("#win button[data-w]").forEach((x) => x.classList.toggle("on", +x.dataset.w === w));
    document.querySelectorAll("#more-menu button[data-w]").forEach((x) => x.classList.toggle("on", +x.dataset.w === w));
    $("more-btn").classList.toggle("on", long);
    $("more-label").textContent = long ? { 604800: "7d", 2592000: "30d", 7776000: "90d" }[w] : "More";
    try { localStorage.setItem("dd-w", String(w)); } catch (e) { /* none */ }
    refreshPage(true);
  }
  document.querySelectorAll("#win button[data-w]").forEach((b) => b.addEventListener("click", () => setWindow(+b.dataset.w)));
  const menu = $("more-menu");
  function openMenu(open) {
    menu.hidden = !open; $("more-btn").setAttribute("aria-expanded", open);
    if (open) {
      const days = state.statsDays || 90;
      menu.querySelectorAll("button[data-w]").forEach((b) => { b.disabled = +b.dataset.w > days * 86400; });
      $("more-note").textContent = `Statistics are kept for ${days} days. Change it in Settings › Data & logs.`;
    }
  }
  $("more-btn").addEventListener("click", (ev) => { ev.stopPropagation(); openMenu(menu.hidden); });
  menu.querySelectorAll("button[data-w]").forEach((b) => b.addEventListener("click", () => { openMenu(false); setWindow(+b.dataset.w); }));
  document.addEventListener("click", (ev) => { if (!menu.hidden && !menu.contains(ev.target)) openMenu(false); });
  document.addEventListener("keydown", (ev) => { if (ev.key === "Escape") openMenu(false); });
  async function refreshPage(full) {
    const p = state.page, jobs = [];
    if (p === "overview") jobs.push(loadDnsdist(), loadBind(), loadLive(), loadSummary(), loadSeries(), loadLatency(), loadTop(), loadClients());
    if (p === "queries") jobs.push(loadLog(), loadClients(), loadClient());
    const res = await Promise.allSettled(jobs);
    const bad = res.find((r) => r.status === "rejected" && r.reason && r.reason.message !== "auth");
    if (bad && full) console.warn(bad.reason);
  }
  let tick = 0;
  setInterval(() => { if (!document.hidden) loadHost().catch(() => setLive(false)); }, 5000);
  setInterval(() => {
    if (document.hidden) return;
    tick++;
    const p = state.page;
    if (p === "overview") { loadLive().catch(() => {}); if (tick % 2 === 0) { loadSummary().catch(() => {}); loadTop().catch(() => {}); loadBind().catch(() => {}); } if (tick % 4 === 0) { loadSeries().catch(() => {}); loadLatency().catch(() => {}); loadClients().catch(() => {}); } }
    if (p === "queries") { if ($("f-live").checked) loadLog().catch(() => {}); if (tick % 4 === 0) { loadClients().catch(() => {}); loadClient().catch(() => {}); } }
    if (p === "settings" && state.sub === "service" && tick % 3 === 0) loadService().catch(() => {});
  }, 5000);
  setInterval(() => { if (!document.hidden && state.page === "overview") loadDnsdist().catch(() => {}); }, 2000);
  let rz;
  window.addEventListener("resize", () => { clearTimeout(rz); rz = setTimeout(() => { Object.values(charts).forEach((c) => { c.svg = null; }); refreshPage(); }, 250); });

  // ================================================================ start
  try { const w = +localStorage.getItem("dd-w"); if ([900, 3600, 21600, 86400, 604800, 2592000, 7776000].includes(w)) state.w = w; } catch (e) { /* none */ }
  document.querySelectorAll("#win button[data-w]").forEach((x) => x.classList.toggle("on", +x.dataset.w === state.w));
  if (state.w > 86400) { $("more-btn").classList.add("on"); $("more-label").textContent = { 604800: "7d", 2592000: "30d", 7776000: "90d" }[state.w]; }
  loadHost().catch(() => {});
  api("/api/session").then((s) => { CSRF = s.csrf; state.user = s.user; }).catch(() => {}).finally(route);
})();
DNSDASH_FILE_END
cat > "$APP/web/favicon.svg" <<'DNSDASH_FILE_END'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2ea6ff"/><stop offset=".45" stop-color="#5e5ce6"/><stop offset=".8" stop-color="#bf5af2"/><stop offset="1" stop-color="#ff4f7b"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#g)"/><path d="M18 20l14 25 14-25" fill="none" stroke="#fff" stroke-width="5.2" stroke-linecap="round" stroke-linejoin="round"/><circle cx="18" cy="20" r="4.4" fill="#fff"/><circle cx="46" cy="20" r="4.4" fill="#fff"/><circle cx="32" cy="45" r="4.4" fill="#fff"/></svg>
DNSDASH_FILE_END
chown -R root:root "$APP"; chmod 644 "$APP"/*.py "$APP"/web/*
python3 -m py_compile "$APP/dnsdash.py" "$APP/agent.py" || die "python files do not compile"
rm -rf "$APP/__pycache__"

# ----------------------------------------------------------------- BIND configuration (rendered by the agent)
step "Backing up /etc/bind to $BACKUP"
cp -a /etc/bind "$BACKUP" || die "backup failed"
[ -d /etc/dnsdist ] && cp -a /etc/dnsdist "$BACKUP-dnsdist"
[ -s /etc/bind/rndc.key ] || rndc-confgen -a -c /etc/bind/rndc.key
chown root:bind /etc/bind/rndc.key; chmod 640 /etc/bind/rndc.key

restore_and_die() {
    echo "!! Restoring /etc/bind from $BACKUP"
    systemctl stop dnsdist 2>/dev/null || true
    rm -rf /etc/bind && cp -a "$BACKUP" /etc/bind
    [ -d "$BACKUP-dnsdist" ] && rm -rf /etc/dnsdist && cp -a "$BACKUP-dnsdist" /etc/dnsdist
    systemctl restart named 2>/dev/null || true
    die "$*"
}

step "Writing dnsdist and BIND configuration"
if [ ! -f "$ETCD/settings.json" ]; then
    DD_IP="$IP" DD_LISTEN="$LISTEN_JSON" DD_FW="$FORWARDERS" DD_LAN="$LAN" python3 -I - <<'PYSET'
import json, os
e = os.environ
s = {"version": 1,
     "resolver": {"listen": json.loads(e["DD_LISTEN"]), "forwarders": json.loads(e["DD_FW"]), "query_acl": ["any"],
                  "rate_limit": {"enabled": False, "qps": 300, "exempt": ["127.0.0.1/32"]}},
     "local": {"zone": "huvafen.internal", "records": [
         {"name": "ns1", "type": "A", "value": e["DD_IP"], "ttl": None},
         {"name": "_aaplcache._tcp", "type": "TXT", "value": "prs=123.176.25.78,123.176.25.118", "ttl": 10800}]}}
with open("/etc/dnsdash/settings.json", "w") as f:
    json.dump(s, f, indent=2)
os.chmod("/etc/dnsdash/settings.json", 0o600)
PYSET
fi
# ns1 must point at this server; the listen choice above replaces the saved one
DD_IP="$IP" DD_MODE="$MODE" DD_HOST_IPS="127.0.0.1 $ALL_IPS" python3 -I - <<'PYNS'
import json, os
p = "/etc/dnsdash/settings.json"
s = json.load(open(p))
recs = s.get("local", {}).get("records", [])
changed = False
ip, host = os.environ["DD_IP"], set(os.environ["DD_HOST_IPS"].split())
res = s.setdefault("resolver", {})
old = list(res.get("listen", []))
if os.environ["DD_MODE"] == "all":
    new = ["any"]
else:
    keep = [a for a in old if a in host and a not in ("127.0.0.1", ip)]   # drops "any" and addresses no longer on this server
    new = ["127.0.0.1", ip] + keep
if new != old:
    print("DNS listen:", " ".join(old) or "-", "->", " ".join(new))
    res["listen"] = new; changed = True
fw = res.get("forwarders", [])
cf = [a for a in fw if a not in ("8.8.8.8", "8.8.4.4")] or ["1.1.1.1", "1.0.0.1"]
if cf != fw:
    print("Upstreams:", " ".join(fw), "->", " ".join(cf), "(Google removed, Cloudflare only)")
    res["forwarders"] = cf; changed = True
if s.get("blocking", {}).get("enabled"):
    print("Blocking: on -> off (not used with dnsdist in front)")
    s["blocking"]["enabled"] = False; changed = True
for r in recs:
    if r.get("name") == "ns1" and r.get("type") == "A" and r.get("value") != os.environ["DD_IP"]:
        print(f"ns1.{s['local'].get('zone', 'huvafen.internal')}: {r['value']} -> {os.environ['DD_IP']}")
        r["value"] = os.environ["DD_IP"]; changed = True
if changed:
    with open(p + ".tmp", "w") as f:
        json.dump(s, f, indent=2)
    os.chmod(p + ".tmp", 0o600)
    os.replace(p + ".tmp", p)
PYNS
python3 -I "$APP/agent.py" --render || restore_and_die "rendering the configuration failed"
named-checkconf -z /etc/bind/named.conf >/dev/null || restore_and_die "named-checkconf rejected the configuration"
dnsdist --check-config -C /etc/dnsdist/dnsdist.conf || restore_and_die "dnsdist rejected the configuration"
echo "OK: configuration valid"

step "Starting BIND (127.0.0.1:$BIND_PORT) and dnsdist (port 53)"
systemctl enable named dnsdist >/dev/null 2>&1
systemctl restart named || { journalctl -u named -n 30 --no-pager; restore_and_die "named failed to start"; }
for i in $(seq 1 20); do rndc status >/dev/null 2>&1 && break; sleep 1; done
rndc status | grep -E 'zones|running' || restore_and_die "BIND is not answering rndc"
systemctl restart dnsdist || { journalctl -u dnsdist -n 30 --no-pager; restore_and_die "dnsdist failed to start"; }
for i in $(seq 1 15); do dig @127.0.0.1 +tries=1 +time=1 ns1.huvafen.internal A +short | grep -q . && break; sleep 1; done
dnsdist -C /etc/dnsdist/dnsdist.conf -c -e 'showServers()' 2>/dev/null | sed 's/^/  /'

# ----------------------------------------------------------------- dashboard login + certificate
step "Dashboard login"
RESET="y"
if [ -f "$ETCD/config.json" ]; then
    read -r -p "A dashboard login already exists. Keep it? [Y/n] " ans < /dev/tty
    case "$ans" in n|N) RESET="y" ;; *) RESET="n" ;; esac
fi
DUSER=""; PW1=""
if [ "$RESET" = "y" ]; then
    read -r -p "Dashboard username [admin]: " DUSER < /dev/tty
    DUSER="${DUSER:-admin}"
    while true; do
        read -r -s -p "Password (min 10 characters): " PW1 < /dev/tty; echo
        read -r -s -p "Repeat password: " PW2 < /dev/tty; echo
        [ "$PW1" = "$PW2" ] || { echo "Passwords do not match."; continue; }
        [ ${#PW1} -ge 10 ] || { echo "Too short."; continue; }
        break
    done
fi
DD_USER="$DUSER" DD_PW="$PW1" DD_RESET="$RESET" DD_CFG="$ETCD/config.json" DD_IP="$IP" DD_BIND="$DASH_BIND" DD_PORT="$DASH_PORT" \
DD_LAN="$LAN" DD_DATA="$DATA" DD_ETCD="$ETCD" python3 -I - <<'PYCFG'
import hashlib, json, os, secrets
e = os.environ
path = e["DD_CFG"]
old = json.load(open(path)) if os.path.exists(path) else {}
cfg = {
    "server_ip": e["DD_IP"], "listen": e["DD_BIND"], "port": int(e["DD_PORT"]), "iface": "any",
    "tcpdump": "/usr/bin/tcpdump", "allow": old.get("allow", [e["DD_LAN"], "127.0.0.1/32"]), "retention_hours": 24,
    "run_as": "", "db": e["DD_DATA"] + "/dns.db", "cert": e["DD_ETCD"] + "/cert.pem", "key": e["DD_ETCD"] + "/key.pem",
    "stats_url": "http://127.0.0.1:8053/json/v1/server", "session_hours": 12, "fast_ms": 1.0, "slow_ms": 50,
    "agent_socket": "/run/dnsdash/agent.sock", "dnsdist_secret": e["DD_ETCD"] + "/dnsdist.json",
}
if e["DD_RESET"] == "y":
    salt = secrets.token_bytes(16); it = 600000
    cfg.update(user=e["DD_USER"], salt=salt.hex(), iterations=it,
               hash=hashlib.pbkdf2_hmac("sha256", e["DD_PW"].encode(), salt, it).hex())
else:
    for k in ("user", "salt", "iterations", "hash"):
        cfg[k] = old[k]
with open(path + ".tmp", "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(path + ".tmp", path)
print("login configured for", cfg["user"])
PYCFG
[ $? -eq 0 ] || die "dashboard config write failed"
unset PW1 PW2
chown root:dnsdash "$ETCD/config.json"; chmod 640 "$ETCD/config.json"
SAN="IP:$IP"
[ "$MODE" = "all" ] && SAN="$(for a in $IP $ALL_IPS; do echo "IP:$a"; done | awk '!s[$0]++' | paste -sd, -)"
# new certificate when missing or when it does not cover the address(es) now in use
if [ ! -s "$ETCD/cert.pem" ] || [ ! -s "$ETCD/key.pem" ] || \
   [ "$(openssl x509 -in "$ETCD/cert.pem" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/IPAddress:/IP:/g')" != "$SAN" ]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 -subj "/CN=$IP/O=Huvafen Fushi IT" \
        -addext "subjectAltName=$SAN" -keyout "$ETCD/key.pem" -out "$ETCD/cert.pem" >/dev/null 2>&1 || die "certificate generation failed"
fi
chown root:dnsdash "$ETCD/cert.pem" "$ETCD/key.pem"; chmod 644 "$ETCD/cert.pem"; chmod 640 "$ETCD/key.pem"
FP="$(openssl x509 -in "$ETCD/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)"

# ----------------------------------------------------------------- services
step "Services"
cat > /etc/systemd/system/dnsdash-agent.service <<EOF
[Unit]
Description=VDNS settings service (privileged helper)
After=network-online.target named.service dnsdist.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -I $APP/agent.py
Restart=always
RestartSec=3
RuntimeDirectory=dnsdash
RuntimeDirectoryMode=0755
ProtectSystem=strict
ReadWritePaths=/etc/bind /etc/dnsdist /etc/dnsdash /var/lib/dnsdash-agent /var/log/dnsdash /run/dnsdash
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/dnsdash.service <<EOF
[Unit]
Description=VDNS DNS dashboard
After=network-online.target named.service dnsdist.service dnsdash-agent.service
Wants=network-online.target dnsdash-agent.service

[Service]
Type=simple
User=dnsdash
Group=dnsdash
Environment=DNSDASH_CONFIG=$ETCD/config.json
ExecStart=/usr/bin/python3 -I $APP/dnsdash.py
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$DATA
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_PACKET AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable dnsdash-agent dnsdash >/dev/null 2>&1
systemctl restart dnsdash-agent || die "dnsdash-agent failed to start (journalctl -u dnsdash-agent)"
for i in $(seq 1 10); do [ -S /run/dnsdash/agent.sock ] && break; sleep 1; done
[ -S /run/dnsdash/agent.sock ] || die "settings service socket missing (journalctl -u dnsdash-agent)"
systemctl restart dnsdash || die "dnsdash failed to start (journalctl -u dnsdash)"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 53 comment 'DNS' >/dev/null
    ufw allow from "$LAN" to any port "$DASH_PORT" proto tcp comment 'DNS dashboard' >/dev/null
fi

# ----------------------------------------------------------------- tests
step "Tests"
PASS=0; FAIL=0
chk() { if echo "$2" | grep -Eq "$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1  (got: $(echo $2 | head -c 120))"; FAIL=$((FAIL+1)); fi; }
Q="dig @$IP +tries=1 +time=3"
chk "ns1 points at this server"      "$($Q ns1.huvafen.internal A +short)"                 "^${IP//./\\.}$"
chk "Reverse lookup"                 "$($Q -x $IP +short)"                                 "ns1\.huvafen\.internal"
chk "resolver.arpa answered locally" "$($Q _dns.resolver.arpa SVCB | grep -E 'status|flags:' | tr '\n' ' ')" "NXDOMAIN.*aa"
chk "Apple content caching TXT"      "$($Q _aaplcache._tcp.huvafen.internal TXT +short)"   "prs="
chk "BIND on 127.0.0.1:$BIND_PORT"   "$(dig @127.0.0.1 -p $BIND_PORT +tries=1 +time=3 ns1.huvafen.internal A +short)" "^${IP//./\\.}$"
chk "BIND not on port 53"            "$(ss -lnupH 'sport = :53' | grep -c named)"         "^0$"
chk "External lookup (UDP)"          "$($Q google.com A +short)"                           "^[0-9]+\."
chk "External lookup (TCP)"          "$($Q apple.com A +tcp +short)"                       "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"
chk "Second lookup from cache"       "$($Q www.icloud.com A >/dev/null; $Q www.icloud.com A | grep 'Query time')"  "Query time: [01] msec"
# Cloudflare and Google validate DNSSEC; dnsdist passes their verdict through to clients
dnssec_ad() {
    local i d r=""
    for i in $(seq 1 5); do
        for d in isc.org cloudflare.com ietf.org; do
            r="$($Q $d A +dnssec | grep 'flags:' | head -1)"
            case "$r" in *" ad"*) echo "$d: $r"; return ;; esac
        done
        sleep 2
    done
    echo "$r"
}
chk "DNSSEC validated (ad flag)"     "$(dnssec_ad)"                                        " ad"
chk "DNSSEC bogus rejected"          "$($Q dnssec-failed.org A | grep -E 'status:')"       "SERVFAIL"
if [ "$MODE" = "all" ]; then
    for a in $ALL_IPS; do
        chk "Answers on $a"          "$(dig @"$a" +tries=1 +time=3 ns1.huvafen.internal A +short)" "^${IP//./\\.}$"
    done
fi
chk "Loopback listener"              "$(dig @127.0.0.1 +tries=1 +time=3 ns1.huvafen.internal A +short)" "^${IP//./\\.}$"
# latency of cached answers through dnsdist, measured from this server (network round trip excluded)
echo "  INFO  $(DD_IP="$IP" timeout 60 python3 -I - <<'PYBENCH' 2>&1 | tail -1
import os, socket, struct, time, statistics
ip = os.environ.get("DD_IP", "127.0.0.1")
def q(name, qid):
    p = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    for l in name.split("."): p += bytes([len(l)]) + l.encode()
    return p + b"\x00" + struct.pack("!HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(0.5)
names = ["ns1.huvafen.internal", "www.apple.com", "www.google.com"]
for n in names:
    s.sendto(q(n, 1), (ip, 53)); s.recv(4096)
lat, lost = [], 0
for i in range(1500):
    t = time.perf_counter(); s.sendto(q(names[i % 3], i + 2), (ip, 53))
    try:
        s.recv(4096); lat.append((time.perf_counter() - t) * 1000)
    except socket.timeout:
        lost += 1
lat.sort()
print("%d cached lookups: median %.3f ms, p99 %.3f ms, max %.2f ms, lost %d" % (len(lat), statistics.median(lat), lat[int(len(lat) * .99)], lat[-1], lost))
PYBENCH
)"
DDK="$(python3 -c "import json;print(json.load(open('$ETCD/dnsdist.json'))['api_key'])" 2>/dev/null)"
chk "dnsdist upstreams up"           "$(curl -s -m 5 -H "X-API-Key: $DDK" http://127.0.0.1:8083/api/v1/servers/localhost | python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(s['state'].lower()=='up' for s in d['servers']),'of',len(d['servers']))" 2>&1)" "^[1-9][0-9]* of"
chk "Query logging off"              "$(rndc status)"                                      "query logging is OFF"
chk "Settings service reachable"     "$(ls -l /run/dnsdash/agent.sock)"                    "dnsdash"
ok=0
for i in $(seq 1 15); do [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://$IP:$DASH_PORT/login")" = "200" ] && { ok=1; break; }; sleep 1; done
chk "Dashboard answers on HTTPS"     "$ok"                                                 "^1$"
chk "Dashboard capturing"            "$(journalctl -u dnsdash -n 30 --no-pager)"           "capture started"

if [ "$FAIL" != "0" ]; then
    echo "  Diagnostics for failed checks:"
    echo "    clock: $(date -u '+%F %T UTC')  ntp: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    dnsdist -C /etc/dnsdist/dnsdist.conf -c -e 'showServers()' 2>&1 | sed 's/^/    dnsdist: /'
    journalctl -u dnsdist -n 8 --no-pager 2>/dev/null | sed 's/^/    dnsdist log: /'
    grep -E "listen-on" /etc/bind/named.conf | sed 's/^ */    bind: /'
fi

step "Summary"
echo "  Tests passed: $PASS   failed: $FAIL"
echo "  VDNS:        https://$IP:$DASH_PORT   (from $LAN; login required)"
echo "  DNS on:      dnsdist, $([ "$MODE" = "all" ] && echo "all interfaces ($ALL_IPS)" || echo "$IP and 127.0.0.1"), port 53"
echo "  Routing:     huvafen.internal, private reverse names, _aaplcache -> BIND 127.0.0.1:$BIND_PORT; everything else (cache first) -> $(python3 -c "import json;print(', '.join(json.load(open('$ETCD/settings.json'))['resolver']['forwarders']))" 2>/dev/null)"
echo "  dnsdist:     $(dnsdist --version 2>/dev/null | head -1)"
echo "  Certificate: SHA-256 $FP"
echo "  Settings:    upstreams, cache, routing, local records and data retention are on the Settings page."
echo "               Every change is checked by dnsdist and BIND and logged under Settings > Activity."
echo "  Files:       $ETCD/settings.json (source of truth); /etc/dnsdist/dnsdist.conf and /etc/bind/named.conf (generated)"
echo "  Backup:      $BACKUP"
echo "  Services:    systemctl status dnsdist named dnsdash dnsdash-agent"
echo "  Setup log:   $LOGFILE"
[ "$FAIL" = "0" ] || exit 2
