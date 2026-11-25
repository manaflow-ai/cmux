#!/usr/bin/env bash
set -euo pipefail

swift run --configuration debug --package-path Packages/macOS/CmuxNext CmuxNextTabPolicyCheck
