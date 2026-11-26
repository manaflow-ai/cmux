# 2026-11-24-compile-status-1

Above `if [[ -n "${PR:-}" ]]; then` in the step `Wait for the fleet Release compile and publish cmux-next/compile`'s script (job `compile-status`) in `.github/workflows/cmux-next.yml`.

A controller that accepted this PR head for Release-at-land returns an awaiting_land
receipt. Read it without waiting so the per-tip job can finish before posting pending.
