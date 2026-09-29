# Change management evidence

cmux changes are merged through GitHub pull requests. The default branch is
protected by a repository ruleset that requires at least one approving review
before a pull request can merge. Pull-request authors cannot approve their own
changes.

The approval must come from a contributor other than the pull-request author
and must be recorded in GitHub before merge. Reviewers are responsible for
checking the change, its tests, and the stated verification evidence. Changes
to publish-critical or secret-touching paths also require the matching
CODEOWNER review.

## Exceptions

Historical or incident exceptions are recorded when the normal reviewer path
was unavailable or would have created an incident response delay. The pull
request must record all of the following in its Summary or Testing section:

- the concrete reason an independent review was unavailable;
- the person who approved the exception; and
- the verification or release review that compensates for the missing review.

The active default-branch rulesets require one approving review, dismiss stale
approvals, require approval of the last push, and have no bypass actors. An
exception note does not waive that gate or authorize an author or maintainer to
merge without the required review. If the normal reviewer path is unavailable,
hold the merge until an independent reviewer is available. For a historical or
separately approved incident exception that already merged outside the gate,
attach the exception to the pull request and release record so an auditor can
distinguish it from an unreviewed change. A release review does not
retroactively turn an old pull request into an independently approved pull
request; historical exceptions remain identified as exceptions.

This document describes the engineering change-management process. It is
operational evidence for the applicable compliance controls and is not a claim
of certification or regulatory approval.
