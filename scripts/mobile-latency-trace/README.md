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

Simulator and Mac uptime share a clock domain, so analyze with `--same-clock`:

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
