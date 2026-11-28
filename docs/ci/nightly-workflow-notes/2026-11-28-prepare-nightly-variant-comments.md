# nightly.yml prepare-nightly-variant: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `prepare-nightly-variant:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-4.md

Above `if: always() && (needs.prepare-nightly-variant-primary.result == 'failure' || needs.prepare-nightly-`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-2.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 &`:

    # After a primary success it only reads that result.

Above `- *put-llvm-lipo-on-path-as-lipo`:

    # llvm-lipo as lipo: put-llvm-lipo-on-path.sh says why.

Above `- *download-signing-inputs-paralle`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-reuse-a-successful-primary-preparati-3.md

Above `- *download-nightly-ghostty-license-trees`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-reuse-a-successful-primary-preparati-4.md

Above `- *prove-the-browser-data-import`:

    # The cx-f58x browser-data scan, when build-nightly-app did not prove this app.

Above `- *inject-nightly-ghostty-licenses`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-reuse-a-successful-primary-preparati-2.md

Above `- *verify-shipped-libintl-has-its`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-1.md

Above `- *verify-nightly-binary-archs`:

    # The same gate as prepare-nightly-variant-primary (one copy keeps nightly.yml under its size limit).

Above `- *record-prepared-app-digest`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-reuse-a-successful-primary-preparati-5.md
