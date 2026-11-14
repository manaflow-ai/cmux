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

## Proof preconditions and pairing ceremony

A recovery proof must establish its initial permission state through the supported
off command and read it back: new phones now inherit Full access on. The proof
uses its own daemon home and refuses ambiguous or revoked phone records.
Detector: `tests/test_owner_access_proof.py`, followed by the real paired simulator
proof; a hardcoded receipt flag alone is not evidence.

New phones inherit Full access on (#42732), so pairing keeps the standard Allow
action and does not ask for the same grant twice. The redundant Full-access
button, copy and pending-setting path are removed. The phone recovery action
remains for an explicit-off setting. Detector: `pairingPromptKeepsOneAllowAction`
checks the phone and Mac pairing sheets; the real proof captures the sheet and
requires its single Allow action before exercising explicit-off recovery.
