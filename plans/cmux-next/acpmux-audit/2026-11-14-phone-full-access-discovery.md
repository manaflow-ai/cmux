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
