set -e
cd webviews
bun run gallery:build >/tmp/gb.log 2>&1 || { tail -50 /tmp/gb.log; exit 1; }
bun scripts/gallery/capture-states.mjs "$1" "$2"
