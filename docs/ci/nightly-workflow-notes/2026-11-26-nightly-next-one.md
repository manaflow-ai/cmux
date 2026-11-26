# nightly.yml `nightly-next-one`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- name: Mint the release App token for the warm checkout`

After the claim (the release App key comes after it, rule 7a of
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py): the key reaches only the action, the
read-only token only the warm checkout's env, which keeps .publish-tooling through its clean. One installation token for this checkout, so its GitHub reads spend the App's own
quota (5,000+ an hour) and never the Mac's shared unauthenticated per-IP limit (run 45744507889).

## 2

Above: `- name: Package unsigned app for signer shadow`

It is shadow-only: the current in-job signing path remains authoritative, and
the upload is skipped unless the repository variable is explicitly `on`.

## 3

Above: `- name: Refuse stray processes before secrets`

Nothing a build script, a dependency or the app started may still run once a secret is present
(refuse_stray_processes.py). Again before the publication secrets, after the steps that run the app.

## 4

Above: `- name: Notarize app ticket through final DMG`

One Apple round: the DMG's ticket, stapled to the DMG. The app inside carries no ticket of its own
(CMUX_STAPLE_APP_IN_DMG=false); Gatekeeper finds its ticket online, and the verify step below requires
Gatekeeper to call it notarized. Apple gets 40 minutes; a slower build fails this job and the loop's
retry builds again (no hand-off).

## 5

Above: `# in these steps (test_nightly_next_one_job.py under tests). Why: docs/ci/nightly-workflow-notes.md#note-31`

The deltas follow the feed in this job, off the critical path to it (the item above was written full-only),
and never fail the build: every step here continues on error, and each one's `if` names what it needs.
The two that hold the signing key carry no `!cancelled()`, so a failed claim skips them
(tests/test_ci_signing_owned_mac.py).
The delta build signs what the keyless prebuild made when it finished beside the checks, else builds them.
The signing key reaches only the delta build, after a third stray-process check; nothing from the bundle runs

## 6

Above: `- name: Fail when this build's publication was refused`

A refused publication is red, not green: run 45607031207 built and signed, its shelf check died (ENOSPC),
the gate refused, and the job showed green with nothing published, so a 3.5 h stall read as healthy
(2026-11-25). A stand-down (writer linux or none, a known-bad commit), a superseded build and a left slot
publish nothing on purpose and stay green.
