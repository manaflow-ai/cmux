# Windows binaries under Wine: what Linux can and cannot verify

`scripts/ci/wine-smoke.sh` runs the Windows binaries that `scripts/ci/windows-gnu-cross-build.sh` builds
on Linux (x86_64-pc-windows-gnu) under Wine 9.0 (Ubuntu noble `wine64`). The checks themselves are the
Windows runner's, from `cmux-tui-build-package.yml` `build-windows`: the same smoke scripts, run by a
Windows CPython 3.12.10 (the embeddable zip, sha-pinned, with the pywinpty wheel that
`cmux-tui/scripts/requirements-windows-conpty.txt` pins) against the same `.exe` files. Each Windows API
the binary calls goes through Wine's implementation of it.

CI: the `wine-smoke-windows` job in `cmux-tui-build-package.yml`, one matrix leg per binary on a
Linux runner, needs `cross-build-windows` and downloads its artifacts. It adds to `build-windows` and
replaces none of it.

Locally:

```bash
bash scripts/ci/windows-gnu-cross-build.sh build /tmp/dist   # see that script for its env
bash scripts/ci/wine-smoke.sh all /tmp/dist /tmp/dist-tests  # or one: wine-smoke.sh cmux-relay ...
```

The first `setup` takes about 12 s: the Wine prefix, the Python zip and the wheel. After that, a binary's
checks take seconds, and an edit-build-check loop needs no Windows machine.

## Measured (2026-11-26, Wine 9.0, lane VM)

| Binary | Check | Wine | Windows runner |
| --- | --- | --- | --- |
| cmux-relay | `--version` | PASS, 0 s | not checked there |
| cmux-relay | `serve` on loopback; Linux `curl` gets `/healthz` `{"status":"ok"}` and a `101` WebSocket upgrade on `/v1/relay` | PASS, 3 s (ready in under 1 s) | not checked there |
| chatmux-relay | `--version`, `--help` | PASS, 0 s | not checked there |
| cmux-tui | `--version` | PASS, 2 s | run |
| cmux-tui | `remote-probe --json` refuses with "remote daemon commands require Unix sockets" | PASS, 1 s | run |
| cmux-tui | `socket_start_lock_acquires_a_new_lock_file` (`cmux-tui-core-tests.exe`) | PASS, 1 s | run |
| cmux-tui | `registry_opens_and_persists_under_a_long_windows_state_root` | cannot run: resolving the `\\?\` state directory fails under Wine 9.0 with ERROR_MORE_DATA (234) | run |
| cmux-tui | `normalize_long_windows` | matches 0 tests in this binary, under Wine and on the runner alike: those tests moved to `cmux-tui-platform`. The Wine check requires each filter to run at least one test | runs 0 tests |
| cmux-tui | the long state path smoke and the process-exit smoke | cannot run: both start the daemon, which fails with WSAEAFNOSUPPORT (10047) because its Windows socket is AF_UNIX and Wine 9.0 has none | run |
| cmux-tui-hook | `--help` (it has no `--version`: it reads a native event) | PASS, 1 s | not checked there |
| cmux-tui-host | started without a bootstrap pipe, it refuses with "not a bootstrap pipe name" | PASS, 2 s | not checked there |

The relay check exercises Winsock, tokio's Windows I/O driver and TLS-free HTTP over loopback. A
`--version` alone would not.

## What Wine can verify

- The binary loads: its PE imports resolve, the UCRT and MinGW runtime start, and `main` runs. That catches a
  missing DLL, a wrong import or a runtime abort at startup.
- CLI parsing and refusal paths (`--version`, `--help`, `remote-probe` refusing with "remote daemon
  commands require Unix sockets").
- TCP sockets: binding, accepting, HTTP and WebSocket upgrade, tested against a Linux client.
- Files and paths through Win32: creating `\\?\` long paths, `CreateFileW`, `MoveFileExW` and lock files. Wine maps
  these onto the Linux filesystem, so the code paths run, but NTFS's own limits do not apply.
- Process spawn and exit codes via `CreateProcessW` (Python's `subprocess` and the daemon's own spawns).
- Windows Python with native wheels (pywinpty loads; CPython 3.12.10 runs the smoke scripts).

## What Wine cannot verify (stays on the Windows runner)

- **AF_UNIX sockets, so the running daemon.** On Windows the daemon listens on an AF_UNIX socket (Windows
  10 1803 and later). Wine 9.0's Winsock has no AF_UNIX: `socket(AF_UNIX, ...)` fails with WSAEAFNOSUPPORT
  (10047), so `cmux-tui` exits before it publishes its socket. The long state path smoke, the process-exit
  smoke and anything else that talks to a live daemon need the Windows runner. Newer Wine development
  releases add AF_UNIX; recheck when the runner image's Wine moves past 9.0.

- **ConPTY.** Under Wine 9.0, `CreatePseudoConsole` returns `S_OK`, but the child's output goes to the
  parent's own stdout instead of the pseudo console's pipe: 0 bytes came back on the pipe. And
  `ResizePseudoConsole` returns `0x80004001` (`E_NOTIMPL`). pywinpty's `PtyProcess.spawn` fails
  ("ConPTY -> Invalid handle", "WinPTY -> agent died"), with or without a tty. So the ConPTY resize
  smoke (`smoke-windows-conpty-resize.py`) and anything that reads a terminal's output can't run under Wine.
  The probe: `CreatePseudoConsole`, then `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, then
  `ResizePseudoConsole`, then read the pipe.
- **PowerShell.** The install-key handoff (`smoke-windows-install-key-handoff.ps1`) and the resize check's
  `$Host.UI.RawUI.WindowSize` need `pwsh`, which is not part of a Wine prefix.
- **Security and kernel behavior.** Owner-only ACLs (`SetSecurityInfo`), job objects that kill a tree,
  named-pipe security, Defender and SmartScreen, Authenticode and code signing, the registry as a real
  Windows install leaves it, NTFS semantics (case, reserved names, `MAX_PATH` without the long-path key), and
  console code pages.
- **Long `\\?\` path resolution.** Under Wine 9.0, resolving the long state directory in
  `registry_opens_and_persists_under_a_long_windows_state_root` fails with ERROR_MORE_DATA (234). Creating and
  opening long paths works (the lock-file test and the long state tree in the daemon smoke both get that far),
  but the resolve step does not. That test stays on the runner.
- **Performance.** Wine timings are not Windows timings.

A pass under Wine is a fast early signal. Release confidence still comes from `build-windows`.

## Windows runner: GCP VM or Blacksmith (measured 2026-11-19..26)

Stay on Blacksmith. The data, from the Actions API over 20 runs (15 Windows jobs that ran):

- Almost every Windows minute is `cmux-rd-windows.yml`: about 1.3 Windows jobs per run, and 93 of its
  last 100 runs did not skip. `build-windows` was skipped in all 13 sampled `cmux-tui-artifacts.yml` runs.
- Blacksmith `4vcpu-windows-2025`:
  - job p50 / p95: 3.2 / 14.4 min
  - queue p50 / p95: 11 / 16 s
  - price per minute: the baseline
- A GCE `n2-standard-4` Windows VM:
  - price per minute: about 40% of Blacksmith's on demand, 30% spot, Windows license included (quoted)
  - boot: 1.5 to 4 min from an image, or about 0.5 to 1 min from a stopped, prebaked disk
  - also needs an image, a just-in-time runner and a reaper
- At roughly 12k Windows minutes a month, that saving is small next to the upkeep of our own runner images,
  and each job would wait minutes instead of seconds, on jobs whose median is 3 minutes. Blacksmith's flex scheduling (-40%) is the
  cheaper lever.
- Revisit GCE only if Windows minutes grow more than 10x or a job needs GCE's network or a GPU.
