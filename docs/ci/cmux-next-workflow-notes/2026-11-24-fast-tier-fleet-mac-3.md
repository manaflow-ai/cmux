# 2026-11-24-fast-tier-fleet-mac-3

Above `if [[ -z "$id" && "$line" =~ $step_re ]]; then id="${BASH_REMATCH[1]}"; fi` in the step `Run the fast tier's Swift suites on the build fleet`'s script (job `fast-tier-fleet`) in `.github/workflows/cmux-next.yml`.

The client names its step before the step's own log streams.
