cd webviews
O="${FAST_CHECKS_OUT:?}"
CSS=src/agent-session/acpmux/conversation/unread.css
cp $CSS .nmrow/unread.after.css
cp .nmrow/unread.before.css $CSS
echo "== BASE test"; CMUX_BROWSER_TESTS=1 bun test test/agent-pane-since-on-worked-divider.test.ts 2>&1 | grep -E '^\((pass|fail)\)'
mkdir -p "$O/before" "$O/after"
bun .nmrow/shot.ts "$PWD" "$O/before" > "$O/before.json" 2>/dev/null
cp .nmrow/unread.after.css $CSS
bun .nmrow/shot.ts "$PWD" "$O/after" > "$O/after.json" 2>/dev/null
echo "== AFTER test"; CMUX_BROWSER_TESTS=1 bun test test/agent-pane-since-on-worked-divider.test.ts 2>&1 | grep -E '^\((pass|fail)\)'
ls "$O"/*/ | wc -l
