set -e
cd webviews
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .capture-still-sending.json "$FAST_CHECKS_OUT/after"
