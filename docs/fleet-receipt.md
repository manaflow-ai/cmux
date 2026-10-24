# Fleet receipt action

The `cmux fleet receipt` action packages one useful fleet slice for an outside repository: run a bounded command on the repository's chosen runner and produce a portable JSON receipt with the provider, pool, timing, outcome, and content hash. It does not create cloud resources and does not need credentials.

It is a dry run by default. A dry run records the command hash and planned state without executing it:

```yaml
- uses: manaflow-ai/cmux/.github/actions/fleet-receipt@feat-cmux-next
  with:
    command: npm test
```

Opt in to execution and set a wall clock limit when the command is trusted:

```yaml
- id: linux-check
  uses: manaflow-ai/cmux/.github/actions/fleet-receipt@feat-cmux-next
  with:
    command: npm test -- --runInBand
    execute: "true"
    timeout-seconds: "1200"
    receipt-path: .cmux/receipts/linux-check.json
```

The action sets `status` and `duration-ms` outputs and writes a schema-versioned receipt. The receipt intentionally excludes hostnames, home paths, command text, and environment values. It contains a SHA-256 command digest, runner OS/architecture/CPU count, `FLEET_PROVIDER`, `FLEET_POOL`, GitHub commit/ref when available, start/end timestamps, timeout, and exit outcome. Upload the JSON with the repository's normal artifact action if you want to retain it.

For local checks, the same script is standalone and stdlib-only:

```sh
python3 .github/actions/fleet-receipt/fleet_receipt.py --command 'python -m unittest' --output receipt.json
python3 .github/actions/fleet-receipt/fleet_receipt.py --execute --timeout-seconds 60 --command 'python -m unittest' --output receipt.json
```

Execution runs in a process group and terminates the group on timeout. The action itself has no provider adapter: a fleet controller can consume the stable receipt and route jobs separately, while an outside repository can adopt the format before connecting a provider.
