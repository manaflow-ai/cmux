# Mobile latency tracing

Tracing is DEBUG-only and off by default. For a tagged Mac build, enable it for
that bundle and relaunch:

```bash
defaults write com.cmuxterm.app.debug.slat cmux.debug.latency-trace -bool true
./scripts/reload.sh --tag slat --launch
```

`CMUX_LATENCY_TRACE=1` is the equivalent process environment gate. The Mac log
is `/tmp/cmux-debug-slat.log`.

For an iOS Simulator, enable tracing and the optional typing probe at launch:

```bash
SIMCTL_CHILD_CMUX_LATENCY_TRACE=1 \
SIMCTL_CHILD_CMUX_LATENCY_PROBE=40:250 \
xcrun simctl launch <udid> <ios-bundle-id>
```

The probe waits for a connected shell with a mounted terminal, waits another
three seconds, then sends the configured number of single characters through
the production input path.

Find the simulator log with:

```bash
data_dir="$(xcrun simctl get_app_container <udid> <ios-bundle-id> data)"
ios_log="$data_dir/Library/Application Support/cmux-debug.log"
```

A simulator and Mac app running on the **same host** share an uptime clock.
Only for that pairing, analyze with `--same-clock`:

```bash
python3 scripts/mobile-latency-trace/analyze.py \
  --mac-log /tmp/cmux-debug-slat.log \
  --ios-log "$ios_log" \
  --same-clock
```

Omit `--same-clock` for physical-iPhone captures. Add `--json` for raw joined
duration arrays. Run the embedded fixture check with:

```bash
python3 scripts/mobile-latency-trace/analyze.py --selftest
```

## Trace format

Every per-surface render/input-ack stamp carries `s=<surface>`, where
`<surface>` is the first eight lowercase hexadecimal characters of the surface
UUID:

- Mac: `host.tee`, `host.grid`, `host.enq`, `host.write`, `host.in.recv`, and
  `host.in.applied`.
- iOS: `ev.grid`, `gate`, `ap.yield`, `ap.done`, `rd.present`, and `in.resp`.

Mac `host.enq` and `host.write` stamps also carry `conn=<connection>`, the first
eight characters of the subscriber connection ID. The analyzer joins render
and input-ack stages by `(s, seq)`. When the same `(s, seq)` appears repeatedly,
it preserves first-at-or-after time ordering; for host fan-out, the earliest
connection write supplies each wire sample.

Raw-input batches continue to use their process-local `n=<batch>` identity:
`in.send` marks departure from the iOS drain loop and `in.settled` marks the
actual response/error settlement (`ok=1` for success, `ok=0` for failure).
Because `in.resp` and `in.settled` are emitted from the same pipelined
settlement, the analyzer associates the next `in.resp` at or after each
successfully settled `in.send` even if its log timestamp follows `in.settled`.

## Physical iPhone capture

Use the normal same-tag sign-in and pairing launcher with tracing enabled. From
an hq-created cmux worktree, after installing the tagged pair:

```bash
DEVICECTL_CHILD_CMUX_LATENCY_TRACE=1 scripts/mobile-dev-launch.sh \
  --tag ilat --device --device-id 4A52829D-6427-599F-A166-4058881D2DF4 \
  --ensure-mac --auth-profile personal \
  --credentials-file "$HOME/.secrets/cmuxterm-dev.env"
```

Tracing applies to this process launch. Keep the app running during capture;
a normal home-screen relaunch does not preserve the environment override.
Enable the Mac trace separately as above, using the same tag.

After reproducing, copy the phone log while it is connected and unlocked:

```bash
xcrun devicectl device copy from \
  --device 4A52829D-6427-599F-A166-4058881D2DF4 \
  --domain-type appDataContainer --domain-identifier dev.cmux.ios.ilat \
  --source 'Library/Application Support/cmux-debug.log' \
  --destination /tmp/cmux-ios-ilat.log
python3 scripts/mobile-latency-trace/analyze.py \
  --mac-log /tmp/cmux-debug-ilat.log --ios-log /tmp/cmux-ios-ilat.log
```

The sink rotates to `cmux-debug.log.1`; copy that file too if the reproduction
crossed a rotation. Keep one process launch and one workload per analysis;
identifiers may reset after relaunch. These new events contain timings, IDs,
counts and operation labels, not typed text. The surrounding debug log can
contain terminal content, so keep captures local.

## Local queue diagnosis

`in.ui` marks delivery of text, backspace, or escape input to the terminal view.
It does not measure the delay before UIKit invokes that callback and is not a
unique keystroke identifier (pastes and composed text can contain many bytes).

`oq.enqueue`, `oq.wait`, and `oq.run` carry a queue ID `q`, operation number
`op`, and operation label. `oq.wait us=...` measures enqueue entry to worker
entry, including enqueue-lock acquisition and scheduling. `oq.run us=...`
measures the synchronous work closure, excluding the wait-stamp emission; it
does not include later main-actor callbacks or GPU completion. The enqueue
`depth` counts pending operations, excluding work already executing.
`oq.reject` records a refused operation. `tick.alive` maps queue IDs to surfaces
and includes pending depth and cumulative rejection count for that generation.
Other queue callers use `normal`/`priority`; output application and rendering
have explicit labels. Timings remain valid across interleaved queue logs
because each operation records its own elapsed duration.

Capture these comparable workloads for 20–30 seconds each on the same phone,
Mac, route and terminal dimensions:

1. Type individual characters, then a short burst, in an idle shell.
2. Repeat while terminal output is arriving continuously.
3. Repeat with tracing disabled to check whether instrumentation changes the symptom.

Use the measured delays to choose the next investigation:

- Rising queue wait and depth: inspect which work occupies the serial worker.
- Long queue work: profile the relevant output or render closure.
- Short queue timings but late input settlement/output receipt: inspect the
  transport and host stages already present in the trace.
- Early input/output with late presentation: inspect main-thread scheduling and
  frame admission, then capture an Instruments trace if needed.

Check `trace.dropped` before interpreting missing events or percentiles. A
physical phone and Mac have different uptime clocks; never subtract their
absolute timestamps. The existing echo and next-response associations are
proxies, not proof that a specific manually typed character reached the
screen. Background output, pipelined inputs and coalesced frames can make those
associations ambiguous. Do not tune queue limits or batching from a single
aggregate percentile without the surrounding timeline and workload.
