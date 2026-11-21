# acpmux, the agent daemon

How cmux keeps agents running: sessions, harnesses, machines, and the daemon.

acpmux keeps coding agents running as named sessions. One acpmux daemon runs on each machine. cmux starts it; the app's chats, the cmux CLI, and other agents are all clients of it. When the app quits or updates, your agents keep working.

## Sessions

A session is one agent conversation. It has a name of up to 80 letters, digits, dots, dashes, and underscores. A session on another machine is MACHINE/NAME. acpmux records every message a session sends and receives, on disk, so any client can attach later and read the whole conversation.

cmux acp gives you acpmux from the cmux CLI:

```bash
cmux acp ls                                       # sessions on every machine
cmux acp new -n fix-tests -m codex -d "Fix the failing test"
cmux acp send fix-tests "Also run the linter"
cmux acp wait fix-tests --print                   # wait for the turn, print the reply
cmux acp last fix-tests                           # the last reply
```

## Harnesses

A harness is the agent program a session runs: Claude Code, Codex, and other agents. acpmux talks to agents with the Agent Client Protocol (ACP), and through adapters to agents that speak their own protocol. Each harness is a profile in ~/.config/cmux/harnesses/ that says how to start it.

```bash
cmux acp daemon harnesses   # the harnesses this daemon knows
cmux acp daemon models      # the models each one offers
cmux harness add gateway --example anthropic-endpoint --base-url https://llm.example.com --model MODEL
```

## Machines

The acpmux daemons on your machines link up, over SSH or your private network. Then a session on any of them shows in your sidebar, and you can start one where you like. A message to a session can also go through your team's hub in cmux Cloud: it is delivered at least once and runs once, wherever that session runs.

```bash
cmux acp machine ls         # your machines and their connection state
cmux acp machine status     # health: reachable, disk, load, sessions, build
cmux acp machine pick       # which machine a new session would go to, and why
```

## The daemon

```bash
cmux acp daemon status
cmux acp daemon restart     # sessions resume after
cmux acp daemon shutdown    # agents keep running for the next daemon
```

The daemon also keeps the cost ledger: when a turn ends, it adds the turn's cost and tokens. Read it with cmux acp ledger.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/acpmux`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux) | The agent daemon and its CLI |
| [`cmux-tui/crates/acpmux/docs/cli-sessions.md`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/docs/cli-sessions.md) | Every session command |
| [`cmux-tui/crates/acpmux/docs/cli-harnesses.md`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/docs/cli-harnesses.md) | Harness profiles and how to add one |
| [`cmux-tui/crates/acpmux/docs/cli-hosts.md`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/docs/cli-hosts.md) | Machine commands |
| [`cmux-tui/crates/acpmux/harnesses`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/harnesses) | The harness profiles cmux ships |
| [`cmux-tui/crates/acpmux/src/mesh.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/mesh.rs) | Messages between sessions through the team hub |

- [How cmux NEXT fits together](architecture.md)
- [Agents and subagents](agents.md)
- [Audit agent spend](agent-spend.md)
- [Run agents on your own API keys](own-keys.md)
- [Machines](machines.md)
