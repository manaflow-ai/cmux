#!/usr/bin/env bash
# RETIRED 2026-10-05. Human approval of Testbox runs was removed on purpose on
# 2026-10-05; the cmux-ci App approves registered boxes. A missing reviewer is
# expected, not a security problem. Start every box with the cmuxterm-hq
# wrapper, which registers the box so the App approves its run:
#
#   HQ_TOOLS=<your cmuxterm-hq checkout on main>
#   git -C "$HQ_TOOLS" pull --ff-only
#   "$HQ_TOOLS/scripts/testbox-warmup.sh" --lane <lane>
#
# (exit 4 = registration failed: report it, do not retry by hand). This
# helper approves nothing and always exits 2.
cat >&2 <<'MSG'
blacksmith-testbox-approve.sh is retired: human approval of Testbox runs was
removed on purpose on 2026-10-05; the cmux-ci App approves registered boxes.
A missing reviewer is expected, not a security problem. Nothing was approved.
Start the box with the wrapper instead:
  HQ_TOOLS=<your cmuxterm-hq checkout on main>
  git -C "$HQ_TOOLS" pull --ff-only
  "$HQ_TOOLS/scripts/testbox-warmup.sh" --lane <lane>
(exit 4 = registration failed: report it, do not retry by hand)
Without cmuxterm-hq access, run focused cargo test inside cmux-tui/ locally
(see cmux-tui/README.md) and say so in the PR.
MSG
exit 2
