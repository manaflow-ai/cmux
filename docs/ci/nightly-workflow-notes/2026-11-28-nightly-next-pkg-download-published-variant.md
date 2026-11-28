# 2026-11-28-nightly-next-pkg-download-published-variant

Where: `.github/workflows/nightly.yml`, job `nightly-next-pkg`, step "Download published variant": above `- name: Import signing cert for the .pkg`.

The managed keychain, made in its own step so only this step holds the certificate; next-pkg.sh signs from it (NEXT_PKG_KEYCHAIN_READY) and the always() cleanup deletes it.
