set +e
mv webviews/zz-tmp /tmp/zz-tmp
F=src/agent-session/acpmux/conversation
cd webviews
bun run check > /tmp/c0.log 2>&1; echo "@@CHECK0_EXIT=$?"; tail -40 /tmp/c0.log | sed 's/^/@@C0 /'
bun run check:fix > /dev/null 2>&1; git diff -- . ':!zz-tmp' | sed 's/^/@@DIFF /'
bun run check > /tmp/c.log 2>&1; echo "@@CHECK_EXIT=$?"
bun test $F/ShellBlock.test.tsx test/transcript-block-overflow.test.tsx > /tmp/g.log 2>&1; echo "@@GREEN_EXIT=$?"; grep -A12 '::error' /tmp/g.log | head -40 | sed 's/^/@@GREEN /'; grep -E '\(fail\)|^ *[0-9]+ (pass|fail)' /tmp/g.log | sed 's/^/@@GREEN /'
cp /tmp/zz-tmp/base-ShellBlock.tsx $F/ShellBlock.tsx; cp /tmp/zz-tmp/base-conversation.css $F/conversation.css
bun test $F/ShellBlock.test.tsx > /tmp/b.log 2>&1; grep -E '\(fail\)|^ *[0-9]+ (pass|fail)' /tmp/b.log | sed 's/^/@@BASE /'
echo END
