# Startup performance

The startup benchmark compares two exact cmux-tui commits. It uses product output and public socket commands as readiness events. It does not use sleeps, file-existence or socket-path polling for synchronization, quiet periods, or retry polling.

## Scenarios

- Cold starts a new interactive process with fresh isolated state. The event ends after the raw PTY stream contains its unique session label and a later frame-end cursor visibility command.
- Warm starts an attach client after a headless daemon has printed its readiness line and answered session current ping. The event ends at the attach client's first complete frame.
- Headless starts a new daemon. The event ends after the readiness line and a successful session current ping.
- Restored creates a real terminal through the public CLI, stops the daemon, and restarts it with the same state. The event ends after the readiness line and a terminal list response that contains the saved terminal ID.
- Incompatible changes a valid registry schema to an unsupported value. The event ends at nonzero process exit and requires the exact schema error. The benchmark also proves that startup did not change the stored schema.

Each cold and headless launch uses a fresh process, configuration root, and state root. The workflow does not clear the operating system page cache.

## Method

The hosted workflow builds the baseline and candidate in separate target directories. Each scenario has 10 warmup pairs and 50 measured pairs. Even pairs run the baseline first. Odd pairs run the candidate first. A failure to observe an event stops the job. Timing differences do not fail the job because shared hosted computers have variable load.

The JSON artifact contains samples in run order and sorted order. It reports minimum, mean, population standard deviation, median absolute deviation, p50, p90, p95, p99, and maximum. Paired deltas use candidate minus baseline. Negative deltas mean that the candidate was faster.

The artifact records exact source, Ghostty, and binary identities. It also records the runner image, CPU, physical and logical core counts, memory, kernel, Rust, Cargo, and Zig versions.

Run the workflow from GitHub for comparable evidence. The workflow uploads JSON, Markdown, metadata, diagnostics, and available native profiles.

## Native profiles

The example has a one-sample profile mode. A launcher prefix can wrap only the measured process and still pass PTY input and output. Linux uses this mode with strace. macOS records all processes with xctrace while the harness keeps direct PTY ownership. Filter that trace to the exact cmux-tui process and binary recorded in the adjacent profile report. Windows records the event harness inside a system-wide WPR capture. All native profile attempts are non-gating. They record permission or tool diagnostics when a profile is unavailable.

Profile mode still validates the selected source SHA, Ghostty SHA, binary hash, and scenario event. It writes `startup-profile-<target>-<scenario>.json`.
