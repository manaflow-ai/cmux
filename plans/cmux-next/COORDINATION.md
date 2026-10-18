See plans/cmux-next/coordination/INDEX.md for the generated coordination ledger.

2026-10-18: `remote-link --mux-socket` adds an owner-only local admin
`mux-binding` read and retains the checked link connection through stdio relay.
Explicit target mismatches refuse reuse without stopping the existing sidecar;
unqualified SSH and Cloud entry behavior stays compatible. No public action,
remote method allowlist or enrollment authority changes. See server-reach.md.

# General server enrollment

The Rust `server pair` and read-only `server pair status` entrypoints use the existing human-approved backend flow. General servers and Chief hosts share begin proofs, fingerprint/check words and pushed-result validation in `cmux-server-core::pairing::enrollment`. The private record preserves the key and known pending attempt across retries; public status distinguishes pending, indeterminate and completed enrollment. Pairing records enrollment separately from transport/role health and adds no App, agent or remote execution authority. Details: [server pairing](../../cmux-tui/crates/cmux-server/docs/pairing.md).
