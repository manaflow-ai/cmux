#!/usr/bin/env python3
"""After a cmux NIGHTLY-identity attempt: retire, keep or mark the submission; count a failure? (cx-x7hwx)

Usage: nightly-next-legacy-resolve.py --action new|continue --pending true|false
           --notarize success|failure|skipped|cancelled --published true|false
           --apple accepted|refused|unknown [--requirement-refused true|false]

--apple is Apple's final answer about the submission: accepted when the app
carries a valid stapled ticket or the notary log says Accepted (an Accepted
continuation is stapled and writes no log), refused when the log says Invalid
or Rejected, unknown otherwise.

Prints:
  retire=true|false          delete the continued submission's artifacts
  mark_accepted=true|false   store metadata "accepted": true for its bundle, so
                             later runs continue it with no time limit and never
                             submit the build again
  real=true|false            a failure of this attempt counts ("Build N failed:")

Rules (hq-a3, 2026-10-15):
- A submission still in Apple's queue (--pending true) is kept and never counts.
- A published continuation is retired.
- An Accepted submission is never retired by a later failure (a staple, spctl,
  smoke or license check, or the publication): its bundle is kept and marked
  accepted, the failure counts, and the next run re-staples, re-checks and
  publishes it. The target job stops after 2 counted failures of the build.
- Apple refused the continued submission: retire it and count; the next run
  submits anew.
- A continued submission whose attempt failed before Apple answered (for example
  notarytool info failed) is kept and does not count.
- The macOS job refused the app because its own commit lacks a commit in
  NIGHTLY_LEGACY_REQUIRED_COMMITS (--requirement-refused true, before any Apple
  submission): never counted; a continued submission is retired, because that
  build must never be published.
- A failed new attempt counts. (A new submission Apple accepted within the wait
  keeps no bundle: notarize-nightly-dmg.sh writes no state for it.)
"""
import argparse
import sys


def flag(value):
    if value not in ("true", "false"):
        raise argparse.ArgumentTypeError("true or false")
    return value == "true"


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=["new", "continue"], required=True)
    parser.add_argument("--pending", type=flag, required=True)
    parser.add_argument("--notarize", choices=["success", "failure", "skipped", "cancelled"], required=True)
    parser.add_argument("--published", type=flag, required=True)
    parser.add_argument("--apple", choices=["accepted", "refused", "unknown"], required=True)
    parser.add_argument("--requirement-refused", type=flag, default=False)
    args = parser.parse_args(argv)

    retire = mark = real = False
    if args.requirement_refused:
        retire = args.action == "continue"
    elif args.pending:
        pass
    elif args.action == "new":
        real = True
    elif args.published:
        retire = True
    elif args.apple == "accepted":
        mark, real = True, True
    elif args.apple == "refused":
        retire, real = True, True
    # continue, Apple did not answer: keep, no count
    for key, value in (("retire", retire), ("mark_accepted", mark), ("real", real)):
        print(f"{key}={'true' if value else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
