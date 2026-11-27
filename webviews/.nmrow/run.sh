cd webviews
O="${FAST_CHECKS_OUT:?}"
CSS=src/agent-session/acpmux/conversation/unread.css
cp $CSS .nmrow/unread.after.css
mkdir -p "$O/vafter" "$O/vbefore"
bun .nmrow/video.ts "$PWD" "$O/vafter" 2>&1 | tail -3
cp .nmrow/unread.before.css $CSS
bun .nmrow/video.ts "$PWD" "$O/vbefore" 2>&1 | tail -3
cp .nmrow/unread.after.css $CSS
ls -la "$O"/v*/
