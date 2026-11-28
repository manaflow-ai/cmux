# nightly.yml nightly-next-pkg: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `- name: Import signing cert for the .pkg`:

    # The managed keychain, made in its own step so only this step holds the certificate;
    # next-pkg.sh signs from it (NEXT_PKG_KEYCHAIN_READY) and the always() cleanup deletes it.

Above `- name: Build, sign, notarize and upload the pre-warming .pkg`:

    # From the build ref: build-pkg.sh and the postinstall match the app they package.
