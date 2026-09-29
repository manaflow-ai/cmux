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

An exception is allowed only when the normal reviewer path is unavailable or
would create an incident response delay. The pull request must record all of
the following in its Summary or Testing section before merge:

- the concrete reason an independent review was unavailable;
- the person who approved the exception; and
- the verification or release review that compensates for the missing review.

The exception is attached to the pull request and release record so an auditor
can distinguish an approved exception from an unreviewed change. A release
review does not retroactively turn an old pull request into an independently
approved pull request; historical exceptions remain identified as exceptions.

This document describes the engineering change-management process. It is
operational evidence for the applicable compliance controls and is not a claim
of certification or regulatory approval.
