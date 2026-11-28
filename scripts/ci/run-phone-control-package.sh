#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root/Packages/Shared/CmuxPhoneControl"
swift test
swift run cmux-phone self-test
