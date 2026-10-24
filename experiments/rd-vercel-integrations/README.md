# cmux integration adapter prototype

This R&D slice turns a single cmux NEXT or acpmux event into provider-shaped
requests for GitHub, Linear, Slack, Vercel-style previews, and cloud-machine
receipts. It has no SDK or network dependency. `DryRunTransport` captures the
requests for inspection; a production transport can add authentication outside
this package, so credentials never enter event payloads, logs, or manifests.

```sh
python3 experiments/rd-vercel-integrations/integrate.py event.json
```

Events are immutable and carry a deterministic id, source (`cmux-next` or
`acpmux`), subject, and redacted JSON payload. Preview events preserve immutable
commit/URL data plus branch and agent aliases. Machine events preserve provider,
generation, receipt, and expiry so allocation, suspend, fork, and delete can be
reconciled by the cloud control plane.
