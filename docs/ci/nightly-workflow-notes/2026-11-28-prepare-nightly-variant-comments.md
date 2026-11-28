# nightly.yml prepare-nightly-variant: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 &`:

    # After a primary success it only reads that result.

Above `- *put-llvm-lipo-on-path-as-lipo`:

    # llvm-lipo as lipo: put-llvm-lipo-on-path.sh says why.

Above `- *prove-the-browser-data-import`:

    # The cx-f58x browser-data scan, when build-nightly-app did not prove this app.

Above `- *verify-nightly-binary-archs`:

    # The same gate as prepare-nightly-variant-primary (one copy keeps nightly.yml under its size limit).
