G=src/agent-session/acpmux/conversation/LiveLineUnderTray.gallery.ts; T=test/agent-pane-live-line-under-tray.test.ts
bun run fmt $G $T 2>&1 | tail -2
echo "BEGIN_G $(base64 -w0 < $G) END"; echo "BEGIN_T $(base64 -w0 < $T) END"
bun run fmt --check $G $T >/dev/null 2>&1; echo "fmt=$?"
bun run check:fixed-waits >/dev/null 2>&1; echo "fw=$?"
bun scripts/check-frame-reads.ts >/dev/null 2>&1; echo "fr=$?"
