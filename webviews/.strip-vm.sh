set -e
cd /work
mkdir -p out
(bun install --frozen-lockfile >out/install.log 2>&1) || { tail -30 out/install.log; exit 3; }
(bunx playwright install --with-deps chromium webkit >out/pw.log 2>&1) || { tail -30 out/pw.log; exit 4; }
CMUX_TEST_ARTIFACTS=/work/out bun test test/composer-hat-line-align.test.ts > out/log.txt 2>&1 || true
tail -150 out/log.txt
