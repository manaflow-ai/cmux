# nightly.yml: job `nightly-next-one`, step "Notarize app ticket through final DMG"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

One Apple round: the DMG's ticket, stapled to the DMG. The app inside carries no ticket of its own
(CMUX_STAPLE_APP_IN_DMG=false); Gatekeeper finds its ticket online, and the verify step below requires
Gatekeeper to call it notarized. Apple gets 40 minutes; a slower build fails this job and the loop's
retry builds again (no hand-off).
