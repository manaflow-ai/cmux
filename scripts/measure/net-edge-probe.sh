#!/usr/bin/env bash
# The network edge the cmux NEXT iPhone link meets, measured from this host with no credentials
# (RFD 0049's baseline for the warm link):
#   scripts/measure/net-edge-probe.sh
# The Cloudflare colo this host lands on (/cdn-cgi/trace), the addresses the relay and STUN hosts
# resolve to, ICMP ping to the relay (N pings, 0.2 s apart), and for both addresses a raw STUN binding
# round trip on UDP 3478, a TCP connect and a TLS handshake on 443; for each API host N fresh-connection
# GETs of /v1/health (TCP connect, TLS done, first byte, from curl -w) beside /cdn-cgi/trace on the same
# host (the edge alone). Prints p50/p95/max per row as a markdown table headed by the host name and UTC
# time. Env: NET_EDGE_N (20), NET_EDGE_RELAY_HOST (turn.cloudflare.com), NET_EDGE_STUN_HOST
# (stun.cloudflare.com), NET_EDGE_API_HOSTS ("mobile-api.cmux.dev cloud-api.cmux.dev"),
# NET_EDGE_TRACE_URL (https://www.cloudflare.com/cdn-cgi/trace). Needs curl, python3; ping is optional.
set -uo pipefail
n="${NET_EDGE_N:-20}"
relay_host="${NET_EDGE_RELAY_HOST:-turn.cloudflare.com}"
stun_host="${NET_EDGE_STUN_HOST:-stun.cloudflare.com}"
api_hosts="${NET_EDGE_API_HOSTS:-mobile-api.cmux.dev cloud-api.cmux.dev}"
trace_url="${NET_EDGE_TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
samples="$work/samples.tsv" # ROW<TAB>MS, one line per successful sample
notes="$work/notes.txt"
: >"$samples"
: >"$notes"

resolve() { getent ahostsv4 "$1" 2>/dev/null | awk '$2 == "STREAM" { print $1 }' | sort -u | tr '\n' ' '; }
first_addr() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'; }

trace="$(curl -s --max-time 10 "$trace_url" || true)"
colo="$(printf '%s\n' "$trace" | sed -n 's/^colo=//p')"
echo "edge colo ($trace_url): ${colo:-unknown} (ip $(printf '%s\n' "$trace" | sed -n 's/^ip=//p'), loc $(printf '%s\n' "$trace" | sed -n 's/^loc=//p'))" >>"$notes"
relay_ip="$(first_addr "$relay_host")"
stun_ip="$(first_addr "$stun_host")"
echo "$relay_host resolves to: $(resolve "$relay_host")" >>"$notes"
echo "$stun_host resolves to: $(resolve "$stun_host")" >>"$notes"

if [ -n "$relay_ip" ] && command -v ping >/dev/null 2>&1; then
  ping -n -c "$n" -i 0.2 -W 2 "$relay_ip" 2>/dev/null |
    sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p' | while read -r ms; do
      printf 'ping %s (%s)\t%s\n' "$relay_host" "$relay_ip" "$ms"
    done >>"$samples"
fi

# A raw STUN binding (RFC 5389) on UDP 3478, then TCP connect and TLS handshake on 443, per address.
python3 -I - "$n" "$relay_host" "$relay_ip" "$stun_host" "$stun_ip" >>"$samples" 2>>"$notes" <<'PY'
import os, socket, ssl, struct, sys, time

n = int(sys.argv[1])
pairs = [(sys.argv[2], sys.argv[3]), (sys.argv[4], sys.argv[5])]

def stun(host, ip):
    mapped = None
    for _ in range(n):
        tid = os.urandom(12)
        req = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + tid
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        t = time.perf_counter()
        try:
            s.sendto(req, (ip, 3478))
            d, _ = s.recvfrom(2048)
            if d[8:20] == tid and struct.unpack("!H", d[:2])[0] == 0x0101:
                print(f"STUN binding UDP/3478 {host} ({ip})\t{(time.perf_counter() - t) * 1000:.3f}")
                i = 20
                while i + 4 <= len(d):
                    at, ln = struct.unpack("!HH", d[i:i + 4])
                    if at == 0x0020 and ln >= 8:
                        port = struct.unpack("!H", d[i + 6:i + 8])[0] ^ 0x2112
                        addr = bytes(x ^ y for x, y in zip(d[i + 8:i + 12], b"\x21\x12\xa4\x42"))
                        mapped = f"{socket.inet_ntoa(addr)}:{port}"
                    i += 4 + ln + (-ln % 4)
        except OSError:
            pass
        finally:
            s.close()
        time.sleep(0.05)
    print(f"STUN {host} ({ip}) mapped this host to {mapped}", file=sys.stderr)

def tcp_tls(host, ip):
    ctx = ssl.create_default_context()
    for _ in range(n):
        t = time.perf_counter()
        try:
            s = socket.create_connection((ip, 443), timeout=3)
        except OSError:
            continue
        t1 = time.perf_counter()
        print(f"TCP connect :443 {host} ({ip})\t{(t1 - t) * 1000:.3f}")
        try:
            with ctx.wrap_socket(s, server_hostname=host):
                print(f"TLS handshake :443 after TCP {host} ({ip})\t{(time.perf_counter() - t1) * 1000:.3f}")
        except (OSError, ssl.SSLError):
            s.close()
        time.sleep(0.05)

for host, ip in pairs:
    if ip:
        stun(host, ip)
        tcp_tls(host, ip)
    else:
        print(f"{host}: did not resolve", file=sys.stderr)
PY

# Fresh-connection GETs: each curl is its own process, so no connection or TLS session is reused.
for host in $api_hosts; do
  for path in /v1/health /cdn-cgi/trace; do
    for _ in $(seq "$n"); do
      curl -s -o /dev/null --max-time 10 -w '%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer}\n' \
        "https://$host$path" || true
    done | awk -v row="GET https://$host$path" '
      $1 != "000" {
        printf "%s: TCP connect\t%.3f\n", row, $2 * 1000
        printf "%s: TLS done\t%.3f\n", row, $3 * 1000
        printf "%s: first byte\t%.3f\n", row, $4 * 1000
        codes[$1]++
      }
      END { for (c in codes) printf "%s: HTTP %s x%d\n", row, c, codes[c] > "/dev/stderr" }' >>"$samples" 2>>"$notes"
  done
done

python3 -I - "$n" "$(hostname)" "$samples" "$notes" <<'PY'
import sys, time

n, host, samples, notes = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
rows = {}
for line in open(samples):
    row, _, ms = line.rstrip("\n").rpartition("\t")
    if row:
        rows.setdefault(row, []).append(float(ms))

def pct(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

print(f"## net-edge-probe from {host}, {time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime())}\n")
for line in open(notes):
    print(f"- {line.rstrip()}")
print("\n| row | ok/n | p50 ms | p95 ms | max ms |\n|---|---|---|---|---|")
for row, xs in rows.items():
    print(f"| {row} | {len(xs)}/{n} | {pct(xs, .5):.1f} | {pct(xs, .95):.1f} | {max(xs):.1f} |")
PY
