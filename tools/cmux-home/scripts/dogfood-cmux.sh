#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
home_dir="$(cd "$script_dir/.." && pwd)"
state_path="${CMUX_HOME_STATE:-$home_dir/examples/state.sample.json}"
workspace_name="${CMUX_HOME_WORKSPACE_NAME:-cmux home}"
focus="${CMUX_HOME_FOCUS:-true}"

if ! command -v cmux >/dev/null 2>&1; then
  echo "cmux CLI not found on PATH" >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to build the cmux layout JSON" >&2
  exit 127
fi

if [[ ! -f "$state_path" ]]; then
  echo "state file not found: $state_path" >&2
  exit 1
fi

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

rust_cmd="cd $(shell_quote "$home_dir/rust") && cargo run -- --data $(shell_quote "$state_path")"
go_cmd="cd $(shell_quote "$home_dir/go") && go run ./cmd/cmux-home --data $(shell_quote "$state_path")"
ts_cmd="cd $(shell_quote "$home_dir/typescript") && bun src/cli.ts --data $(shell_quote "$state_path")"

layout="$(
  jq -nc \
    --arg rust "$rust_cmd" \
    --arg go "$go_cmd" \
    --arg ts "$ts_cmd" \
    '{
      direction: "horizontal",
      split: 0.36,
      children: [
        {
          pane: {
            surfaces: [
              { type: "terminal", command: $rust }
            ]
          }
        },
        {
          direction: "vertical",
          split: 0.5,
          children: [
            {
              pane: {
                surfaces: [
                  { type: "terminal", command: $go }
                ]
              }
            },
            {
              pane: {
                surfaces: [
                  { type: "terminal", command: $ts }
                ]
              }
            }
          ]
        }
      ]
    }'
)"

cmux ping >/dev/null

cmux new-workspace \
  --name "$workspace_name" \
  --description "Dogfood Rust, Go, and TypeScript cmux home prototypes" \
  --cwd "$home_dir" \
  --layout "$layout" \
  --focus "$focus"
