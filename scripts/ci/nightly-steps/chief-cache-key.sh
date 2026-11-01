#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Prepare the OptChat Chief cache key". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
rm -rf .nightly-optchat-chief
[[ "$SOURCE_KEY" =~ ^[0-9a-f]{64}$ ]] || { echo "portable Chief key unavailable; using the local keyed fallback"; exit 0; }
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' cmux-tui/rust-toolchain.toml)"
[[ -n "$toolchain" ]] || { echo "Chief portable key unavailable; using the local keyed fallback"; exit 0; }
if ! rustup toolchain install "$toolchain" --profile minimal >/dev/null; then
  echo "Chief toolchain unavailable; using the local keyed fallback"; exit 0
fi
if ! computed_key="$(python3 scripts/cmux-next/optchat-chief-input-key.py --portable --archs "$ARCHS" --toolchain "$toolchain")"; then
  echo "Chief portable key failed on this checkout; using the local keyed fallback"; exit 0
fi
if [[ "$computed_key" != "$SOURCE_KEY" ]]; then
  echo "Chief portable key differs from the resolved source; using the local keyed fallback"; exit 0
fi
if ! environment_key="$(python3 scripts/cmux-next/optchat-chief-input-key.py --environment --archs "$ARCHS" --toolchain "$toolchain")"; then
  echo "Chief environment key failed; using the local keyed fallback"; exit 0
fi
[[ "$environment_key" =~ ^[0-9a-f]{64}$ ]] || { echo "Chief environment key invalid; using the local keyed fallback"; exit 0; }
arch_key="${ARCHS//,/ }"; arch_key="${arch_key// /-}"
cache_key="cmux-next-optchat-chief-${SOURCE_KEY}-${environment_key}-${arch_key}"
cache_root=".nightly-optchat-chief"
# Cache keys are immutable and an exact restore reports a hit whatever
# its contents, so an entry that fails validation could never be
# replaced under one key. Each save is a new generation under a key
# unique to this run; the restore asks for that (absent) key and takes
# the newest generation through the prefix, so a repaired entry wins.
# Deleting the bad entry instead would need actions: write.
save_key="${cache_key}-g${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
restore_prefix="${cache_key}-g"
result_file="$RUNNER_TEMP/optchat-chief-cache-result"
rm -f "$result_file"
{
  echo "source_key=$SOURCE_KEY"
  echo "environment_key=$environment_key"
  echo "cache_key=$cache_key"
  echo "save_key=$save_key"
  echo "restore_prefix=$restore_prefix"
  echo "cache_root=$cache_root"
} >> "$GITHUB_OUTPUT"
{
  echo "CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEY=$SOURCE_KEY"
  echo "CMUX_NEXT_OPTCHAT_CHIEF_ENVIRONMENT_KEY=$environment_key"
  echo "CMUX_NEXT_OPTCHAT_CHIEF_REQUIRE_IDENTITY=1"
  echo "CMUX_NEXT_OPTCHAT_CHIEF_CACHE=$cache_root"
  echo "CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE=$result_file"
} >> "$GITHUB_ENV"
