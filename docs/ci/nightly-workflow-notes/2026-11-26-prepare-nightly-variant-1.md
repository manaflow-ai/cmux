# 2026-11-26-prepare-nightly-variant-1

Above `- *verify-shipped-libintl-has-its` (job `prepare-nightly-variant`) in `.github/workflows/nightly.yml`.

GNU libintl is LGPL-2.1-or-later. GhosttyKit and the ghostty CLI helper
are built with -Di18n=false, so no shipped Mach-O may define a libintl
symbol unless the channel release carries gettext-0.24.tar.gz and
COPYING.LIB (the prune step keeps those names, they carry no build number).
