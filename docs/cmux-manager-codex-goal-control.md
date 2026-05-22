# cmux-manager Codex goal control

This is a research note for teaching `$cmux-manager` how to set, pause, resume, and swap Codex goals across orchestrated cmux workspaces.

## Summary

Codex has a real app-server RPC surface for goals:

- `thread/goal/set`
- `thread/goal/get`
- `thread/goal/clear`
- `turn/start`
- `turn/steer`
- `turn/interrupt`
- `thread/resume`
- `thread/fork`
- `thread/compact/start`
- `thread/rollback`

The clean path is to launch future managed Codex agents through an app-server-backed thread, store the `threadId` in cmux resume metadata or `~/.cache/cmux-manager-loop/`, and use the RPCs above. That path is better than terminal key tricks because it gives structured state, explicit goal status, turn IDs, and notifications.

The current limitation is that the app-server controls app-server threads. It does not automatically give `$cmux-manager` control over an arbitrary already-running Codex TUI session in a cmux terminal unless that TUI is attached to the same app-server and the manager knows the `threadId`. For existing cmux workspaces, the safe working prototype remains terminal-level control: send prompts, `escape`, and `ctrl+c` through cmux to the Codex surface.

## CLI surfaces checked

Checked in this order:

```bash
codex --help
codex remote-control --help
codex app-server --help
codex app-server daemon --help
codex app-server proxy --help
```

Additional revealed subcommands checked:

```bash
codex remote-control start --help
codex remote-control stop --help
codex app-server daemon bootstrap --help
codex app-server daemon start --help
codex app-server daemon restart --help
codex app-server daemon enable-remote-control --help
codex app-server daemon disable-remote-control --help
codex app-server daemon stop --help
codex app-server daemon version --help
codex app-server generate-json-schema --help
codex app-server generate-ts --help
codex resume --help
codex fork --help
codex exec --help
codex exec resume --help
```

Commands touching goal, turn, or session state:

- `codex resume [SESSION_ID] [PROMPT]`, resumes a persisted interactive session.
- `codex fork [SESSION_ID] [PROMPT]`, forks a persisted interactive session.
- `codex exec resume [SESSION_ID] [PROMPT]`, resumes a session non-interactively.
- `codex app-server`, exposes app-server protocol requests.
- `codex app-server daemon start|restart|stop|bootstrap|enable-remote-control|disable-remote-control`, manages the durable app-server daemon.
- `codex remote-control start|stop`, convenience wrapper around app-server daemon remote control.
- `codex app-server generate-json-schema --experimental`, emits the authoritative JSON schema.
- `codex app-server generate-ts --experimental`, emits TypeScript bindings.

There is still no `codex goal` CLI subcommand.

## Local config

Relevant `~/.codex/config.toml` findings:

```toml
[features]
goals = true
plugins = true
multi_agent = true
```

No app-server or remote-control socket settings were present in config. `codex app-server daemon version` failed because the default control socket did not exist:

```text
failed to connect to /Users/lawrence/.codex/app-server-control/app-server-control.sock
```

`codex remote-control start` did not start on this machine because the CLI was installed from Bun, not from the standalone Codex installer that the daemon manager expects:

```text
managed standalone Codex install not found at /Users/lawrence/.codex/packages/standalone/current/codex
```

`codex app-server daemon stop` reported `{"status":"notRunning","socketPath":"/Users/lawrence/.codex/app-server-control/app-server-control.sock","cliVersion":"0.132.0"}` after the failed start.

`codex doctor --json` produced no output before a 20 second alarm killed it. Treat that as a local diagnostic issue, not as protocol evidence.

## Generated protocol

Generated into temp dirs with:

```bash
codex app-server generate-json-schema --experimental --out /tmp/cmux-codex-goal-control-schema
codex app-server generate-ts --experimental --out /tmp/cmux-codex-goal-control-ts
```

Important request methods from generated `ClientRequest.ts`:

```text
thread/start
thread/resume
thread/fork
thread/archive
thread/unarchive
thread/list
thread/loaded/list
thread/read
thread/turns/list
thread/turns/items/list
thread/inject_items
thread/goal/set
thread/goal/get
thread/goal/clear
thread/compact/start
thread/rollback
turn/start
turn/steer
turn/interrupt
remoteControl/enable
remoteControl/disable
remoteControl/status/read
```

Goal shape:

```ts
type ThreadGoal = {
  threadId: string;
  objective: string;
  status: "active" | "paused" | "blocked" | "usageLimited" | "budgetLimited" | "complete";
  tokenBudget: number | null;
  tokensUsed: number;
  timeUsedSeconds: number;
  createdAt: number;
  updatedAt: number;
};
```

Goal set params:

```ts
type ThreadGoalSetParams = {
  threadId: string;
  objective?: string | null;
  status?: ThreadGoalStatus | null;
  tokenBudget?: number | null;
};
```

Turn interrupt params:

```ts
type TurnInterruptParams = {
  threadId: string;
  turnId: string;
};
```

Turn steer params:

```ts
type TurnSteerParams = {
  threadId: string;
  input: UserInput[];
  expectedTurnId: string;
  responsesapiClientMetadata?: Record<string, string> | null;
};
```

## RPC proof

The durable daemon manager could not be used on this machine because it requires a standalone Codex install. An isolated app-server was started for experiments instead. `unix:///tmp/...` failed because `/tmp` is a symlink on this Mac; `unix:///private/tmp/<dir>/server.sock` starts successfully. For direct protocol testing, stdio was easier and reliable:

```bash
codex app-server
```

Initialize:

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cmux-manager-goal-probe","title":null,"version":"0.1.0"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}
```

Start a thread:

```json
{"id":2,"method":"thread/start","params":{"cwd":"/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-codex-goal-control","approvalPolicy":"never","sandbox":"danger-full-access","experimentalRawEvents":false,"persistExtendedHistory":false}}
```

The server returned thread `019e4cd9-1f9a-7873-a3dd-5d7227be23d0`.

Set a paused goal:

```json
{"id":14,"method":"thread/goal/set","params":{"threadId":"019e4cd9-1f9a-7873-a3dd-5d7227be23d0","objective":"Reply exactly: resumed goal control test.","status":"paused","tokenBudget":50000}}
```

Resume it:

```json
{"id":15,"method":"thread/goal/set","params":{"threadId":"019e4cd9-1f9a-7873-a3dd-5d7227be23d0","status":"active"}}
```

The active update started a turn automatically and the assistant answered `resumed goal control test.`

Swap the goal:

```json
{"id":17,"method":"thread/goal/set","params":{"threadId":"019e4cd9-1f9a-7873-a3dd-5d7227be23d0","objective":"Reply exactly: swapped goal control test.","status":"active","tokenBudget":50000}}
```

The server updated the objective and started a new turn that answered `swapped goal control test.`

Interrupt a running turn:

```json
{"id":10,"method":"turn/interrupt","params":{"threadId":"019e4cd9-1f9a-7873-a3dd-5d7227be23d0","turnId":"65296e52-2d3d-463a-bb11-18485efd344a"}}
```

That returned `{}` and produced a `turn/completed` notification with `status:"interrupted"`.

Important caveat: interrupting a turn while it was running `sleep 60` marked the turn interrupted, but the child `sleep 60` process remained alive and had to be killed manually. Manager code must not assume `turn/interrupt` kills every descendant process.

## Recommended manager design

For future manager-owned Codex sessions:

1. Start or reuse a remote-control app-server daemon.
2. Launch Codex agents in a way that gives the manager a `threadId`, ideally through app-server `thread/start` plus a TUI attached to the same server, or by recording the app-server thread emitted by the launcher.
3. Store `threadId`, workspace ref, surface ref, cwd, title, and current goal under `~/.cache/cmux-manager-loop/codex-goals/`.
4. Use `thread/goal/set status:"paused"` for bookkeeping pause.
5. Use `turn/interrupt` for stopping active work.
6. Use `thread/goal/set status:"active"` to resume an existing paused goal.
7. Use `thread/goal/set objective:"..." status:"active"` to swap.
8. Use `thread/goal/clear` when the manager should stop autonomous pursuit.

For existing Codex TUI workspaces:

```bash
# Set a fresh goal.
cmux send --workspace <workspace> --surface <surface> '<prompt>'
cmux send-key --workspace <workspace> --surface <surface> enter

# Pause without killing the TUI.
cmux send-key --workspace <workspace> --surface <surface> escape

# Resume with a nudge.
cmux send --workspace <workspace> --surface <surface> 'continue with the current goal'
cmux send-key --workspace <workspace> --surface <surface> enter

# Swap, interrupting the current turn and sending a replacement goal.
cmux send-key --workspace <workspace> --surface <surface> ctrl+c
cmux send --workspace <workspace> --surface <surface> '<new prompt>'
cmux send-key --workspace <workspace> --surface <surface> enter
```

Use `scripts/cmux-manager-codex-goal.sh` as the current prototype wrapper. It defaults to `--dry-run` and requires `--apply` before sending keys.

Terminal fallback checks were run only against Codex processes spawned for this experiment:

- `escape` during a running turn changed the TUI to `Conversation interrupted - tell the model what to do differently` and kept the session usable.
- Sending a new prompt after `escape` continued the same session and preserved context.
- `ctrl+c` while idle shut the TUI down and printed a `codex resume <session-id>` command.
- `/quit` exits cleanly when submitted at the idle composer, but it is easy to submit it as ordinary text if the session is still in startup hooks or an active turn. Do not use it for manager pause or swap.
- `SIGSTOP` and `SIGCONT` worked at the POSIX level on a spawned `node .../codex` process (`Ss+` to `Ts+` to `Ss+`), but Codex received no semantic pause event. The process resumed, but app-server, cmux, and manager state had no record of the pause.

## Caveats

- `thread/goal/set status:"paused"` changes goal status and timer accounting. It does not suspend an already-active model stream by itself.
- `thread/goal/set status:"active"` may immediately start autonomous goal pursuit.
- Simple goals can trigger repeated turns until Codex marks the goal complete. Use `thread/goal/clear` to stop pursuit after a manager-driven experiment.
- `turn/interrupt` is structured and preferable to terminal `ctrl+c`, but child shell processes may survive.
- `turn/steer` exists and requires `expectedTurnId`; use it only when the active turn is steerable.
- `thread/compact/start` exists for compaction, but compact turns are explicitly non-steerable.
- `thread/resume` and `thread/fork` are available by `threadId` or persisted path. They are good for session-level lifecycle, not for pausing an active turn.
- Multiple Codex sessions in one cmux workspace require a surface ref or a stored `threadId`; a workspace ref alone is ambiguous.
- Account quota and goal token budgets interact. A low `tokenBudget` moved the test goal into `budgetLimited`; clearing and setting a fresh goal restored normal behavior.
- Do not use SIGSTOP/SIGCONT for manager pause. It freezes the process without telling Codex, the app-server, or cmux what happened, and it can leave child commands or socket state inconsistent.
