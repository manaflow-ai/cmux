cd webviews; bun run protocol:codegen >/dev/null 2>&1
T="src/agent-session/acpmux/session-info test/session-info-section-order.test.tsx test/session-info-compact-default.test.tsx test/session-info-shown-sections.test.tsx src/pages/settings"
bun test $T 2>&1 | grep -E '^\(fail\)' | sed 's/ \[[0-9.]*ms\]//' | sort -u > /tmp/head.fail
git fetch -q --depth=1 origin 124669549b7d1aad97a7fa4a90551255745f41cf; git checkout -q 124669549b7d1aad97a7fa4a90551255745f41cf -- .; bun run protocol:codegen >/dev/null 2>&1
bun test $T 2>&1 | grep -E '^\(fail\)' | sed 's/ \[[0-9.]*ms\]//' | sort -u > /tmp/base.fail
echo "== head $(wc -l </tmp/head.fail) base $(wc -l </tmp/base.fail)"; echo == ONLY_HEAD; comm -23 /tmp/head.fail /tmp/base.fail; echo == ONLY_BASE; comm -13 /tmp/head.fail /tmp/base.fail; echo == END
