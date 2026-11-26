# 2026-11-26-pick-nightly-next-signer-2

Above `nightly-next-pkg:` (job `pick-nightly-next-signer`) in `.github/workflows/nightly.yml`.

RFD 0134 cut 2: the nightly-next app as a .pkg whose postinstall pre-warms a first install. Optional, never
fails the run (next-pkg.sh exits 0); NIGHTLY_NEXT_PKG=off skips it. A certificate with no Installer identity
builds nothing and says so.
