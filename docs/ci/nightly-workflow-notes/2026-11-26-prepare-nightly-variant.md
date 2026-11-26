# nightly.yml `prepare-nightly-variant`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `prepare-nightly-variant:`

The fallback preparation, and the preparation result every later job reads
(needs.prepare-nightly-variant): success after a primary success (a no-op leg) or after
its own preparation. Until 2026-10-31 a separate prepare-nightly-variant job only echoed
that result, one more queued hop on the signing path (4.8 min queued for a 0 s job in
run 41187578702 attempt 2).

## 2

Above: `if: always() && (needs.prepare-nightly-variant-primary.result == 'failure' || needs.prepare-nightly-variant-primary.resu`

Never skipped: a skipped fallback skips signing and publishing (runs 40154003204,
40155340212). After a primary success it finds that result and does nothing.

## 3

Above: `- *download-signing-inputs-paralle`

download-artifact reads each blob over one connection. Fetch all three
signing inputs over ranged HTTP concurrently, while retaining the
action downloads as per-artifact fallbacks if a ranged request fails.

## 4

Above: `- *download-nightly-ghostty-license-trees`

Blocking, like the step that builds it: a nightly-next app always
ships the Ghostty license tree. This is a small artifact containing
only the trees, rather than the complete source offer archive.

## 5

Above: `- *inject-nightly-ghostty-licenses`

The Ghostty dependency license tree (collect-ghostty-licenses.py, checked
by verify-ghostty-license-bundle.py) ships in the app, with the MPL-2.0
source offer that names this release's cmux-next source archive and tag.

## 6

Above: `- *verify-shipped-libintl-has-its`

GNU libintl is LGPL-2.1-or-later. GhosttyKit and the ghostty CLI helper
are built with -Di18n=false, so no shipped Mach-O may define a libintl
symbol unless the channel release carries gettext-0.24.tar.gz and
COPYING.LIB (the prune step keeps those names, they carry no build number).

## 7

Above: `- *record-prepared-app-digest`

nightly-sign.yml (run from main) reads this annotation of this job
through the checks API and refuses a tarball with another sha256.
