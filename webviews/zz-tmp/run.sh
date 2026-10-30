set +e
mv webviews/zz-tmp /tmp/zz-tmp
F=src/agent-session/acpmux/conversation
cd webviews
bun run check > /tmp/c.log 2>&1; echo "@@CHECK_EXIT=$?"; grep -vE '^\s*$' /tmp/c.log | grep -iE 'error|fail|✗|×|warning: ' | grep -vE 'system-accent|0 warnings and 0 errors' | head -30 | sed 's/^/@@CHECK /'
bun test $F/ShellBlock.test.tsx test/transcript-block-overflow.test.tsx > /tmp/g.log 2>&1; echo "@@GREEN_EXIT=$?"; grep -B2 -A25 '(fail)' /tmp/g.log | head -60 | sed 's/^/@@GREEN /'; grep -E '^ *[0-9]+ (pass|fail)' /tmp/g.log | sed 's/^/@@GREEN /'
cp $F/ShellBlock.tsx /tmp/head.tsx; cp $F/conversation.css /tmp/head.css
cp /tmp/zz-tmp/prev-ShellBlock.tsx $F/ShellBlock.tsx
bun test $F/ShellBlock.test.tsx > /tmp/p.log 2>&1; grep -E '\(fail\)|^ *[0-9]+ (pass|fail)' /tmp/p.log | sed 's/^/@@PREV /'
cp /tmp/zz-tmp/base-ShellBlock.tsx $F/ShellBlock.tsx; cp /tmp/zz-tmp/base-conversation.css $F/conversation.css
bun test $F/ShellBlock.test.tsx > /tmp/b.log 2>&1; grep -E '\(fail\)|^ *[0-9]+ (pass|fail)' /tmp/b.log | sed 's/^/@@BASE /'
cp /tmp/head.tsx $F/ShellBlock.tsx; cp /tmp/head.css $F/conversation.css
echo END
