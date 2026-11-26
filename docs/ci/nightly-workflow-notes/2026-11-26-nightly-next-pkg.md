# nightly.yml `nightly-next-pkg`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `nightly-next-pkg:`

RFD 0134 cut 2: the nightly-next app as a .pkg whose postinstall pre-warms a first install. Optional, never
fails the run (next-pkg.sh exits 0); NIGHTLY_NEXT_PKG=off skips it. A certificate with no Installer identity
builds nothing and says so.
