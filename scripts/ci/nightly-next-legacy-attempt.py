#!/usr/bin/env python3
"""Did a cmux NIGHTLY-identity attempt fail? (cx-vws1x)

publish-nightly-identity-legacy asks this after the sign, verify and publish
jobs. Its answer drives the failure report ("Build N failed:", only when
nightly-next-legacy-resolve.py also says real) and the job's red result.

Usage: nightly-next-legacy-attempt.py --sign-result success|failure|cancelled|skipped|""
           --sign-skip true|false|"" --signed-ok true|false|"" --pending true|false|""
           --published true|false --job-ok true|false

Prints failed=true|false. Rules:
- The signing job was cancelled or skipped (a newer run took its concurrency
  slot, or it never started): not a failure; nothing was tried.
- The signing job's order check skipped the build (the old feed has it): not a
  failure.
- The signing job failed before its order check, or any of its steps failed
  (signed_ok is not true): a failure. A submission that is still in Apple's
  queue but could not be kept is a failure too; resolve.py does not count it.
- A submission still in Apple's queue: not a failure.
- Otherwise the build is final at Apple: it failed unless it was published
  (a failed smoke, digest check, appcast or upload is a failure).
- A failed step of the publish job itself is a failure.
"""
import argparse
import sys

RESULTS = ("success", "failure", "cancelled", "skipped", "")
FLAGS = ("true", "false", "")


def failed(sign_result, sign_skip, signed_ok, pending, published, job_ok):
    if sign_result in ("cancelled", "skipped"):
        return False
    if sign_skip == "true":
        return False
    if not job_ok:
        return True
    if sign_skip != "false" or signed_ok != "true":
        return True
    if pending == "true":
        return False
    return not published


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--sign-result", choices=RESULTS, required=True)
    parser.add_argument("--sign-skip", choices=FLAGS, required=True)
    parser.add_argument("--signed-ok", choices=FLAGS, required=True)
    parser.add_argument("--pending", choices=FLAGS, required=True)
    parser.add_argument("--published", choices=("true", "false"), required=True)
    parser.add_argument("--job-ok", choices=("true", "false"), required=True)
    args = parser.parse_args(argv)
    value = failed(args.sign_result, args.sign_skip, args.signed_ok, args.pending,
                   args.published == "true", args.job_ok == "true")
    print(f"failed={'true' if value else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
