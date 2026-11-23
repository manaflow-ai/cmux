#!/usr/bin/env bash
# What the macOS Application Firewall does about the Mac's LAN direct-path listener (UDP 7421,
# cmux-mobile-host's WireGuard mesh): reads the firewall's state and its signed-software rules,
# then binds UDP 7421 on all interfaces for a few seconds, sends itself a datagram over the Mac's
# own LAN address, and reports whether it arrived. It changes no setting.
#
# Run: cmux-ci run --class exclusive --measurement --label measure \
#        --script scripts/measure/macos-firewall-udp-listener.sh --ref SHA
# Output: FIREWALL key=value lines, one per fact.
set -u
fw=/usr/libexec/ApplicationFirewall/socketfilterfw
emit() { printf 'FIREWALL %s=%s\n' "$1" "$2"; }
emit macos "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
if [ -x "$fw" ]; then
  emit global "$("$fw" --getglobalstate 2>&1 | tr -s ' ' | tr '\n' ' ')"
  emit block_all "$("$fw" --getblockall 2>&1 | tr -s ' ' | tr '\n' ' ')"
  emit allow_signed "$("$fw" --getallowsigned 2>&1 | tr -s ' ' | tr '\n' ' ')"
  emit stealth "$("$fw" --getstealthmode 2>&1 | tr -s ' ' | tr '\n' ' ')"
else
  emit global "no socketfilterfw"
fi
for app in "/Applications/cmux NEXT.app" "/Applications/cmux NEXT Nightly.app"; do
  if [ -d "$app" ]; then
    emit "codesign[$(basename "$app")]" "$(codesign -dv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2 | tr '\n' ' ')"
  fi
done
lan_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
emit lan_ip "${lan_ip:-none}"
result=$(/usr/bin/python3 - "$lan_ip" <<'EOF'
import socket, sys
ip = sys.argv[1] or "127.0.0.1"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind(("0.0.0.0", 7421))
except OSError as e:
    print(f"bind_failed:{e.errno}")
    sys.exit(0)
s.settimeout(3)
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
c.sendto(b"cmux-lan-probe", (ip, 7421))
try:
    data, _ = s.recvfrom(64)
    print("received" if data == b"cmux-lan-probe" else "wrong_payload")
except socket.timeout:
    print("no_datagram_in_3s")
EOF
)
emit udp_7421 "$result"
