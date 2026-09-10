# Iroh challenge data migration

Deploy the issuer replacement change to staging and production first. Both
legacy and IRX clients use this broker. No client update or schema change is
required. The slot key is `(user_id, client_namespace, device_uuid, tag)`;
`app_instance_id` is replaced when a build restarts.

Run from `web/` with the same operator AWS access as `cloud-vm:migrate`:

```sh
bun run cloud-vm:cleanup-iroh -- staging
bun run cloud-vm:cleanup-iroh -- staging --apply
bun run cloud-vm:cleanup-iroh -- production
bun run cloud-vm:cleanup-iroh -- production --apply
```

Without `--apply`, the command reports counts only. Apply removes expired and
consumed rows using their existing indexes, then retains the newest pending
challenge in each slot. Equal legacy timestamps are resolved by descending
UUID. Deletes commit in batches of at most 1,000 rows. Duplicate cleanup holds
the same account lock as issuers and reads after taking the lock. Each batch
has a two-second lock timeout and five-second statement timeout; a run has a
15-minute budget. An interrupted run can be repeated safely.

Output contains aggregate counts and allocated table/index bytes, never
account IDs, challenge payloads, or credentials. Success requires zero
expired or duplicate pending rows using the run's start time for expiry,
and zero consumed rows at final verification, including rows consumed during
the run.
Registrations can continue throughout. If locked rows remain or old servers
still create duplicates, the command fails verification and must be rerun.
Ongoing bounded storage depends on keeping the replacement issuer deployed.

The protected `Cloud VM DB migration` workflow also accepts
`cleanup_iroh_challenges=true`. It tests the data migration on isolated
Postgres, then runs staging before production using the existing environment
protections and AWS identity. Production source remains pinned to `main`.

Deletion makes space reusable after PostgreSQL vacuuming; allocated bytes
need not fall immediately. This command does not perform a blocking
`VACUUM FULL`, rebuild indexes, or rewrite the table. Existing scheduled
retention continues removing abandoned expired challenges afterward.
