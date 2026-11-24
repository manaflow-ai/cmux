set -x
cd webviews
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .steered-shots.json "$FAST_CHECKS_OUT/after"; a=$?
git apply -R .steered-before.patch || exit 3
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .steered-shots.json "$FAST_CHECKS_OUT/before"; b=$?
git apply .steered-before.patch
ls -R "$FAST_CHECKS_OUT"
exit $((a+b))
