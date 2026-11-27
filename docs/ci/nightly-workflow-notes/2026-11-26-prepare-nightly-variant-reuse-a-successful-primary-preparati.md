# nightly.yml: job `prepare-nightly-variant`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

GNU libintl is LGPL-2.1-or-later. GhosttyKit and the ghostty CLI helper
are built with -Di18n=false, so no shipped Mach-O may define a libintl
symbol unless the channel release carries gettext-0.24.tar.gz and
COPYING.LIB (the prune step keeps those names, they carry no build number).
