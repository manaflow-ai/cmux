#!/usr/bin/env bash
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  command -v aws
  exit 0
fi

candidates="${CMUX_AWS_CLI_CANDIDATES:-/opt/homebrew/bin/aws:/usr/local/bin/aws:/opt/aws-cli/bin/aws}"
IFS=':' read -r -a candidate_paths <<<"$candidates"
for candidate in "${candidate_paths[@]}"; do
  if [ -x "$candidate" ]; then
    echo "$candidate"
    exit 0
  fi
done

if command -v brew >/dev/null 2>&1; then
  echo "Installing AWS CLI with Homebrew..." >&2
  brew install awscli >/dev/null
  if command -v aws >/dev/null 2>&1; then
    command -v aws
    exit 0
  fi
  for candidate in "${candidate_paths[@]}"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      exit 0
    fi
  done
fi

echo "AWS CLI is required for R2 upload but was not found in PATH or common install paths." >&2
echo "Install awscli on this self-hosted runner or add it to PATH." >&2
exit 127
