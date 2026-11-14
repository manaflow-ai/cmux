# Phone Full access discovery

PR #42731 registers `full-access-approval-v1` for
`_acpmux/pair_full_access_approve`. The phone's pairing banner and chat refusal
both read `initialize._meta.acpmux.capabilities`; a feature in `features` alone
does not make either action available.

This adds one static capability entry, with no session scan, timer or extra
request. `initialize_status_and_the_cli_name_the_same_capabilities` detects a
missing advertisement through a real daemon connection; the registry test
also verifies the wire method exists. The iPhone regression tests cover the
consumed-draft retry and an approval refusal followed by successful recovery.

## Proof preconditions and localized pairing copy

A recovery proof must establish its initial permission state through the supported
off command and read it back: new phones now inherit Full access on. The proof
uses its own daemon home and refuses ambiguous or revoked phone records.
Detector: `tests/test_owner_access_proof.py`, followed by the real paired simulator
proof; a hardcoded receipt flag alone is not evidence.

Both pairing strings now carry every locale already in the catalog. Detector:
`localization_catalog.py check --base-root ... --base-baseline ...`; the original
PR added 16 missing required locale entries, and the corrected catalog adds none.
