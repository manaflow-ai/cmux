#!/usr/bin/env bash
# Build and test the Shared/iOS packages on the Linux VM: every package under Packages/Shared and
# Packages/iOS (plus Packages/macOS/CmuxPhonePush) with at most 2 UI-importing source files, minus
# CmuxHomeRender, CmuxAppAttest and CmuxUpdater (p15-oracle MQ-shared-packages). Same options,
# receipt and errors queue as swift-tier.sh, which does the work:
#
#   swift-shared.sh [--receipt FILE] [--errors-queue FILE] [--only PkgA,PkgB]
#                   [--packages-at-once 6] [--sanitize thread|address] [--jobs 240] [--workers 200]
#
# Expectations: tests/oracle/Expectations.d/swift-shared.txt, a case per package.
exec "$(dirname "${BASH_SOURCE[0]}")/swift-tier.sh" --shared "$@"
