#!/usr/bin/env python3
"""After a cmux NIGHTLY-identity attempt: retire the pending submission? count a failure? (cx-x7hwx)

Usage: nightly-next-legacy-resolve.py --action new|continue --pending true|false
           --notarize success|failure|skipped|cancelled --published true|false --answered true|false

--answered is true when Apple gave a final answer about the submission: the
notary log names Accepted, Invalid or Rejected, or the app carries a valid
stapled ticket (notarize-nightly-dmg.sh staples an Accepted continuation and
writes no log).

Prints:
  retire=true|false   delete the continued submission's artifacts
  real=true|false     a failure of this attempt counts ("Build N failed:")

Rules:
- A submission still in Apple's queue (--pending true) is kept and never counts.
- A continued submission is retired once published, or when Apple answered and
  notarization failed (Invalid, Rejected, or Accepted with a staple/spctl/smoke
  check failing): it can never publish, so the next run submits anew. When
  notarization passed and only the publication failed, it is kept: the next run
  publishes it without a new submission.
- A continued submission whose notarization failed before Apple answered (for
  example notarytool info failed) is kept and does not count.
- Any other failure counts.
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
    parser.add_argument("--answered", type=flag, required=True)
    args = parser.parse_args(argv)

    if args.pending:
        retire, real = False, False
    elif args.action == "new":
        retire, real = False, True
    elif args.published:
        retire, real = True, False
    elif args.notarize == "success":
        retire, real = False, True
    elif args.answered:
        retire, real = True, True
    else:
        retire, real = False, False
    print(f"retire={'true' if retire else 'false'}")
    print(f"real={'true' if real else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
