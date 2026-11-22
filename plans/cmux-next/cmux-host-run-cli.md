# `cmux host run`: the command line grammar (lane 10, 2026-10-05)

Status: spec for the parser. ad349 writes the parser after the remote.rs split. Lane 10's item C
fix (the app's `--probe` guard, red test e663df466b4 on `feat-cmux-next-server-hostprobe`) and
the launchd slice (`feat-cmux-next-server-launchd-r2`, head b21aa66e2dc) wait for the parser and
build on this grammar. The unit command line is frozen as `cmux host run` (server.md 3,
vm-image.md 4.5). The supervisor itself is lane 1's `cmux-host`. This file fixes only its
arguments, exit codes and output.

## 1. Shape

```
cmux host run [--mode <user|system>] [--probe]
```

- `host` is the scope and `run` is the verb. `cmux host` with no verb, or with an unknown verb, is a
  usage error (exit 2).
- No positional arguments. Any positional argument after `run` is a usage error (exit 2).
- Flags may come in any order. Each flag may appear at most once; a repeated flag is a usage
  error (exit 2). `--mode=user` (with `=`) is also accepted. A flag that is not listed here is a
  usage error (exit 2).

## 2. Flags

| flag | type | default | exclusions | meaning |
| --- | --- | --- | --- | --- |
| `--mode <user\|system>` | enum, exactly `user` or `system` (lowercase) | see below | none | the install mode: which store, state folder and service account the supervisor uses (server.md 4.3) |
| `--probe` | boolean, takes no value | off | none; it may be combined with `--mode` (the mode is validated the same way) | answer the support probe and exit. Start nothing (section 4) |

Default of `--mode`: launchd jobs always pass it (`host_run_argv_with_mode`, see section 6). The
systemd and Windows units still set `Environment=CMUX_SERVER_MODE`. They move to `--mode` in the
same landing as the parser. Until that landing, the rule is:
1. use `--mode` when it is given;
2. otherwise, use `CMUX_SERVER_MODE` when it is exactly `user` or `system`;
3. otherwise, use `user`.
Any other value of `CMUX_SERVER_MODE` is a usage error (exit 2). The env fallback is removed when
no unit sets the variable any more. After that, an absent `--mode` means `user`.

The mode is an argument and never a service environment entry, because launchd and systemd pass a
service's environment to every child, including the user's shells (launchd.rs module docs).

## 3. Exit codes

The launchd jobs use `KeepAlive {SuccessfulExit: false}` and `ThrottleInterval 10`, so launchd
restarts a job only after a non-zero exit. Every launchd plist relies on this contract
(launchd.rs `restart_on_failure`):

| code | meaning |
| --- | --- |
| 0 | a deliberate stop: disable, unpair, uninstall, or a stop request. Or a successful `--probe`. Nothing else exits 0. |
| 1 | a runtime failure after the arguments parsed: the store, the state folder, the socket or the lock fails to open, or the lock is lost. launchd restarts the job. |
| 2 | a usage error: an unknown verb, flag or value, a repeated flag, a positional argument, or a bad `CMUX_SERVER_MODE`. Nothing was started. |
| 101 | a panic (the Rust default). It is non-zero, so launchd restarts the job. |

A `cmux` that has no `host` scope (older builds) exits non-zero on `host run --probe`. The app
treats any non-zero exit as "not supported" (section 4).

## 4. Output

`--probe`:
- stdout: exactly one JSON line, then `\n`: `{"host_run":"v1","mode":"<user|system>"}`. `mode` is
  the resolved mode (section 2). Readers ignore unknown keys. A later grammar bumps `host_run`.
- stderr: empty.
- It starts nothing. It opens no store, lock, socket or log, and it writes no file. It exits 0.

A usage error (exit 2):
- stdout: empty.
- stderr: one text line, `cmux host run: <message>`, with the bad flag or value named. The line
  never contains a secret or an environment value other than the bad mode value.

A normal run (no `--probe`):
- stdout: nothing.
- The supervisor writes its own log under the state folder (the app plist sets no
  `StandardOutPath` or `StandardErrorPath`; the headless plists send both to
  `<state>/logs/server.log`).
- stderr: free text, for diagnostics only. No test asserts its content.

The app's probe (item C): `ServerLaunchAgent.hostRunSupported` runs the bundled
`Contents/Resources/bin/cmux host run --probe --mode user`. It is true only when the process exits
0 AND stdout parses as one JSON object whose `host_run` is `"v1"`. A missing binary, a launch
error, any non-zero exit, or other stdout gives false. The app waits for the process through its
termination handler (no polling, no sleep). The probe runs only when the Debug switch is on, before
any SMAppService call.

## 5. Tests that prove each part

App side (Swift, `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/ServerLaunchAgentTests.swift`, red
in e663df466b4):
- `switchOnWithoutHostRunDoesNotRegister`: with the switch on and a CLI without `host run`, the
  agent is not registered. The result is `Failure.hostRunUnsupported`, and the calls are exactly
  `["hostRunSupported"]`.
- `switchOffDoesNotProbeHostRun`: with the switch off, nothing is probed (`Failure.notReady`, no
  calls).
- `switchOnRegisters`, `switchOnKeepsAnEnabledAgent`, `switchOnAsksForApproval`: the probe runs
  first (`"hostRunSupported"` leads the calls), then the SMAppService path is unchanged.
- To add with the probe implementation: a test of the stdout rule in section 4 (exit 0 +
  `host_run: "v1"` gives true; exit 0 with other stdout, or a non-zero exit, gives false).

launchd and units (Rust, `cmux-tui/crates/cmux-server-core/tests/units_golden.rs`, on
`feat-cmux-next-server-launchd-r2`):
- `host_run_argv_with_mode_appends_the_mode`: argv is `<program> host run --mode <user|system>`.
- `launchd_plists_carry_the_mode_as_an_argument`: every launchd plist passes `--mode` in
  `ProgramArguments` and has no `EnvironmentVariables`.
- `app_service_agent_plist_matches_the_bundled_golden`: the app agent plist equals
  `tests/fixtures/app-service-agent.plist` byte for byte: `ProgramArguments`
  `Contents/Resources/bin/cmux host run --mode user`, `KeepAlive {SuccessfulExit: false}`,
  `ThrottleInterval 10`, label `<bundle id>.server`.
- `launch_agent_plist_golden`: the headless agent uses the same argv and restart rule.
- `scripts/cmux-next/tests/bundle-server-helper.test.sh`: the bundled plist that the script stamps
  equals the golden.

Parser tests (the parser landing adds them; suggested names):
- `host_run_parses_mode_and_probe_in_any_order`;
- `host_run_rejects_unknown_flags_repeats_positionals_and_bad_modes_with_exit_2`;
- `host_run_mode_falls_back_to_cmux_server_mode_then_user`;
- `host_run_probe_prints_one_json_line_and_starts_nothing` (no store, lock, socket or log
  created; exit 0);
- `host_run_exits_0_only_on_a_deliberate_stop` (a failed open exits 1).
The last test is the exit contract that `restart_on_failure` names.

## 6. What waits on the parser

- Item C: production `hostRunSupported` changes from `{ true }` to the probe in section 4, and
  e663df466b4 turns green.
- launchd-r2 lands (held until the parser is on the base).
- systemd and Windows units move from `Environment=CMUX_SERVER_MODE` to `--mode` in the same
  landing as the parser, so no unit passes the mode through the environment.
