# Backend VM gateway experiment: resume to backend health

This is the measurement slice of [the backend gateway design](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/plans/cloud/backend-vm-gateway.md). It is an infrastructure experiment, not a Cloud machine idle setting. Nothing runs unless `--experiment backend-vm-gateway` is supplied. No app settings, shared development backend, VM defaults or production routes change.

Use an **isolated, disposable development-backend VM** with the entire stack already running from its memory snapshot. Supply its exact VM id and its own HTTPS `/api/health` URL; no VM is discovered or selected automatically. The endpoint must return JSON `{"status":"ok"}` or `{"status":"healthy"}` after checking the required services. A generic web page, redirect, empty body or non-2xx response fails. The operator must verify that this URL belongs to the supplied VM; this first measurement tool does not provision or discover ingress routes.

Inject `FREESTYLE_API_KEY` through the approved development secret store on the VM runner. Never put it in an argument or report. Compile and run through `cmux-ci`, not a person's Mac:

```sh
cmux-ci test --setup rust -- cargo test --locked --manifest-path scripts/cmux-next/backend-vm-gateway-probe/Cargo.toml
```

On the authorized experiment runner, the explicit invocation is:

```sh
cargo run --locked --manifest-path scripts/cmux-next/backend-vm-gateway-probe/Cargo.toml -- \
  --experiment backend-vm-gateway --dedicated-vm "$BACKEND_PROBE_VM_ID" \
  --health-url "$BACKEND_PROBE_HEALTH_URL" --samples 50 --pause-seconds 60
```

Repeat on the same image/size with `--pause-seconds 600` and `3600`; preserve JSONL output, repository head, snapshot id, VM size and run identity together. Start with the default one-sample pilot before the full matrix. The tool checks that the VM is running and healthy before each pause, waits at most 30 seconds for paused, holds without health traffic, verifies it is still paused, explicitly starts it, then makes exactly one health request with a five-second deadline. No provider credential is sent to health, and redirects are refused on both paths.

Each sample reports the running baseline's health first-byte time, pause acknowledgement, resume acknowledgement, resume-to-first-byte and resume-to-complete-healthy-response. A summary is printed only after every requested sample succeeds; a one-sample pilot cannot meet the 50-sample target. Failures after a pause attempt make one bounded recovery start, report whether it was acknowledged, and exit nonzero. Recovery acknowledgement does not prove backend health. A killed process or machine cannot run recovery: inspect and explicitly start the dedicated VM through the provider console before any retry. Never use a shared or production VM.

The design's existing provider figures are pause about 0.3 s and first exec p50 0.59 s / p95 0.92 s; the internal paused claim is 7.7 s. These are reference measurements, **not results from this probe**. Its target is wake p95 below 2 seconds. The cold-tag target is below 10 seconds, but this tool neither provisions nor measures cold tags. Direct start-to-health excludes the eventual gateway proxy hop; HTTP health alone does not prove database fsync/clock-jump correctness. Memory-snapshot creation, database journey validation, gateway/DO implementation, provider TTL provisioning and automatic idle decisions remain subsequent slices. The settled decision to include background work in idle detection remains in force; this tool never enables `CLOUD_IDLE_PAUSE`.

The regression tests exercise default-off parsing, ordered backend lifecycle, early wake, unhealthy resume, recovery failure, exact sample binding and the HTTP transport. Mock timings prove no provider latency claim.
