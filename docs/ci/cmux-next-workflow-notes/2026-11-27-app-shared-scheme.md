# The app compile consumes the scheme producer

Leo: "stop compiling the same thing in several jobs".

`app-compile-fleet` waits for the optional `cmux-scheme-compile-fleet` job. The controller's app-debug reader
uses a completed exact-head Linux Debug scheme build as the app compile/link evidence. That producer already
uploads `artifacts/cmux.app.zip` to the fleet artifact store for the native scheme/crash-gate consumer.
The app reader needs its verified receipt, not a second download or compile.

The fixed name `cmux-next app compile (shared build fleet)` deliberately has no controller submission hook.
GitHub can send requested/queued events before dependencies resolve; only the job's read may submit its
fallback. The legacy name still submits for older workflow runs. This change must follow the HQ controller
app-debug scheme receipt reuse change; an older controller remains correct but compiles twice.

A skipped scheme producer adds no build to ordinary NEXT PRs. A failed/unavailable scheme producer lets the
existing app check run: a Rust/web/packaging failure does not prove Swift failed. The consumer retains its
`!cancelled()` condition so a skipped or failed dependency does not implicitly skip it. Native sampled parity
coverage is unchanged. Both successful consumers use one app-producing fleet job instead of two.

Detector: `test_cmux_scheme_compile_fleet.py` checks dependency ordering, the read-owned name, skipped-producer
eligibility and absence of cycles; HQ `TestAppDebugSharedProducerBuildCount` measures submitted jobs 2 → 1.
Five real PR CPU/wall comparisons are a separate measurement and are not claimed by this deterministic count.
