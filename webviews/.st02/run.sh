set -e
cd webviews
OUT=${FAST_CHECKS_OUT:-$(pwd)/.st02/out}; mkdir -p $OUT
M=src/agent-session/acpmux/model.ts
cp $M /tmp/fixed.ts
sed -i 's/prev.foldOpen !== true \&\& //' $M
ST02_OUT=$OUT ST02_TAG=before bun test ./.st02/capture.test.ts 2>&1 | tail -5
cp /tmp/fixed.ts $M
ST02_OUT=$OUT ST02_TAG=after bun test ./.st02/capture.test.ts 2>&1 | tail -5
ls -la $OUT
