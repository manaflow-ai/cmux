#!/usr/bin/env bash
# The MessagesLab Swift 6 queue: concurrency diagnostics per
# folder of Packages/Shared/CmuxMessagesLab under complete checking, a flag of this
# build only (messageslab_queue.py). A build runs only as a fleet step:
#   cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/messageslab-queue.sh -- --ref SHA
set -euo pipefail
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/messageslab_queue.py" "$@"
