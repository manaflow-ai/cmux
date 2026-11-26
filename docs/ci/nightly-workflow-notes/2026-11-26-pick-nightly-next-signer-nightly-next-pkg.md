# pick-nightly-next-signer: nightly-next-pkg:

Where: the `pick-nightly-next-signer` job in `.github/workflows/nightly.yml`, above `nightly-next-pkg:`.

RFD 0134 cut 2: the nightly-next app as a .pkg whose postinstall pre-warms a first install. Optional, never
fails the run (next-pkg.sh exits 0); NIGHTLY_NEXT_PKG=off skips it. A certificate with no Installer identity
builds nothing and says so.
