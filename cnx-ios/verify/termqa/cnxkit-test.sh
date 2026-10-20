#!/bin/zsh
# cnxkit-test.sh FILTER: runs CnxKit's swift tests for FILTER on mini-cmux11s
# (never on the laptop). Syncs CnxKit/{Sources,Tests,Package.swift} of this
# checkout into ~/termqa-test/cnx-ios/CnxKit and touches them (rsync keeps
# mtimes, and SwiftPM could reuse a newer build).
set -euo pipefail
here=${0:a:h}
kit=${here:h:h}/CnxKit
host=${CNXKIT_TEST_HOST:-mini-cmux11s-mac-mini}
dir=${CNXKIT_TEST_DIR:-termqa-test}  # one per concurrent agent
ssh $host "mkdir -p ~/${dir}/cnx-ios/CnxKit"
rsync -a --delete $kit/Sources $kit/Tests $kit/Package.swift ${host}:${dir}/cnx-ios/CnxKit/
ssh $host "mkdir -p ~/${dir}/cnx-ios/CnxKit && cd ~/${dir}/cnx-ios/CnxKit && find Sources Tests -name '*.swift' -exec touch {} + && swift test --filter '${1:?filter}' 2>&1 | grep -E 'error:|✘|failed|passed after|Test run with|issue' | tail -${2:-40}"
