#!/usr/bin/env bash
# cmux-next.yml swift-test: "Run CloudBringBack cases in fresh processes", run from Packages/macOS/CmuxNext
# (the step's working-directory).
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
status=0
for test in \
  CloudBringBackTests.aCLIBringBackEndsWithTheChatInALocalTabAndTheMachineTabClosed \
  CloudBringBackTests.aRevokeThatFailsIsTriedAgainUntilItIsDone \
  CloudBringBackTests.aFileAskFromAMovedChatShowsACardAndOnlyThePersonsClickAnswersIt \
  CloudBringBackTests.aSecretAskTakesWhatThePersonTypesOnStdinOnlyAndNoFileHoldsIt \
  CloudBringBackTests.aFileDroppedInAMovedChatGoesToItsMachineFromThisMacsPastesFolderOnly \
  CloudBringBackTests.aSyncConflictKeepsTheMachineTabAndShowsTheConflict \
  CloudBringBackTests.anOutdatedMachineIsNamedAndTheChatStaysOnIt \
  CloudBringBackTests.updateMachineUpdatesAnOutdatedMachineThenBringsTheChatBack \
  CloudBringBackTests.aGuardRefusalKeepsTheMachineTabWithAClearMessage \
  CloudBringBackTests.aGuardRefusalOffersAskFirstThenBringsTheChatBack \
  CloudBringBackTests.aCommittedBringBackWhoseTabFailedStillOpensItAfterARelaunch \
  CloudBringBackTests.aSyncPullThatThrowsKeepsTheBringBackRetryable; do
  echo "Running isolated CloudBringBack case: $test"
  if ../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build --no-parallel --filter "$test"; then
    :
  else
    case_status=$?
    (( status == 0 )) && status=$case_status
    echo "Cloud bring-back case failed: $test (status $case_status)"
  fi
done
exit "$status"
