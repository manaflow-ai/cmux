# nightly.yml: job `nightly-next-pkg`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

RFD 0134 cut 2: the nightly-next app as a .pkg whose postinstall pre-warms a first install. Optional, never
fails the run (next-pkg.sh exits 0); NIGHTLY_NEXT_PKG=off skips it. A certificate with no Installer identity
builds nothing and says so.
