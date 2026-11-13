<!-- SPDX-License-Identifier: MIT -->
# cmux Computer Use as an AgentEnv driver

A `computer_driver` env for [AgentEnv](https://github.com/scaleapi/agentenv-framework) (agentenv-framework 0.9.1521,
protocol 0.1.536) that serves cmux Computer Use, so Scale's port of trycua's Cua Driver Bench
([earakely-scale/agentenv-cua-driver-bench](https://github.com/earakely-scale/agentenv-cua-driver-bench), Apache-2.0)
can run cmux beside its cua-driver, agent-desktop, Codex Computer Use and Aside arms. MIT, like the rest of
`evals/computer-use` ([LICENSE](../../LICENSE)). It is modelled on the framework's own `agent-desktop` and `aside`
drivers.

| File | What it is |
|---|---|
| `env.toml` | The driver env: `[install.linux]` (X11, amd64) and `[install.macos]` (arm64, unverified), port 18765. |
| `driver.py` | `CmuxDriver`: cmux's tools forwarded to `cmux computer-use mcp --primary`, the `computer_*` operations from `X11Driver`, the ready checks, and (run as a script) the daemon service. |
| `mcp.json` | What `cmux computer-use mcp --primary` says at connect and lists at the pinned build: its instructions and its 17 tools. The ready check refuses a binary that serves anything else. |
| `install.sh`, `install-macos.sh` | Unpack the staged cmux binary (Linux), or the CLI and `cmux Remote (dev).app` (macOS). |
| `requirements*.txt` | The driver's venv: the protocol, with its `x11` (Linux) or `macos` extra. |
| `overlay.py` | Puts the driver and cmux variants of the bench's computers, trial files and checks into a checkout of the port. |
| `check_benchlab_cmux.py` | The port's BenchLab check rewritten for cmux's tools: BenchLab's mode checks, IR-01/MB-10/MB-11 solved and IR-01/03/04's interruptions answered in the background, with no model. |

## What the agent gets

The tools and instructions of cmux's own Computer Use MCP server (cmux-tui `acpmux::computer_use::mcp`), at the
pinned build: `status`, `list_machines`, `list_apps`, `list_windows`, `screenshot`, `get_ui_tree`, `click`,
`type_text`, `press_key`, `scroll`, `drag`, `set_value`, `perform_action`, `wait`, `batch`, `launch_app` and
`request_permission`, with their annotations. `--primary` serves the normal instructions (not the "second choice"
ones a Codex client would get). Each MCP session of the agent gets a server of its own, so cmux keeps one Computer Use
session (approvals, agent cursor, element ids) per agent session; idle ones close after 30 minutes, at most 8 are
kept. A server that fails is restarted on the next call; the call that failed says it may have run.

The bench's trial files disable the `computer_*` tools for the agent (the port's `arm_tools` step), so the agent acts
through cmux alone, as the agent-desktop arm acts through agent-desktop's tools alone.

## How cmux runs on the computer (Linux)

- `install.sh` (root, at compose) unpacks `bin/cmux-tui.gz`, which `overlay.py --cmux` staged, to `bin/cmux`. The
  ready check pins its sha256 (`EXECUTABLES` in `driver.py`). The pinned build is cmux-tui at
  `b22c6a09756a0652cf8837159ead4bdc07dbc581` (branch `cmux-cu-rewrite`), built on rbx with `--portable`
  (`cargo build --release --locked -p cmux-tui`), sha256 `2bfd61db...f9ad32`.
- The `daemon` service (`venv/bin/python driver.py`, as the session user under the base's supervisord) waits for the
  X socket, then runs `cmux daemon ensure` from the user's home with `CMUX_CU_HEADLESS=0`, and holds the daemon's
  pid (pidfd) so supervisord restarts the service if the daemon exits. `CMUX_CU_HEADLESS=0` tells cmux a person may
  be watching this display, which the bench's background condition makes true: cmux then never takes the headless
  shortcut (XTest input that moves the real pointer and focus). The same variable is set on every MCP server too.
- The daemon starts the Computer Use worker in the session (DISPLAY, the session bus for AT-SPI) when the first call
  arrives, as on a person's desktop. No policy file is written, so cmux runs its shipped policy: Full access, the
  default deny list, foreground delivery off, pause on takeover, the agent cursor drawn.
- The `driver` service is `agentenv_protocol.computer.serve driver.py:CmuxDriver` on port 18765.
- The `computer_*` operations, `computer-ready`, recording and gate 3's probe are `X11Driver`'s (mss and XTEST from
  the driver's own process), the reference driver's: nothing of the framework's own input goes through cmux.
- `computer-ready` adds four checks, until they pass once: the pinned binary, `cmux daemon status`, the server's
  instructions and tools equal to `mcp.json`, and the worker's `status` (X11, permissions granted).

## macOS (laid out, not verified)

`[install.macos]` takes the cmux CLI and the signed `cmux Remote (dev).app` from a tarball `overlay.py --cmux-macos`
stages (`cmux` and `cmux Remote (dev).app` at its root), installs the CLI to `/usr/local/bin/cmux` and the app to
`/Applications`, and grants the app Accessibility, Post Event and Screen Recording (TCC), since cmux Remote runs the
Computer Use worker on macOS. The daemon is a direct LaunchAgent of the CLI (`cmux daemon start`, with
`CMUX_CU_HEADLESS=0`), and `MacOSDriver` serves the `computer_*` operations. Before a Mac run: confirm `cmux daemon
start` stays in the foreground under launchd (else wrap it as the Linux service does), pin the macOS binary's sha256
in `EXECUTABLES` (`macos/arm64`), take `mcp.json` again from `cmux computer-use mcp --primary` on the Mac (the macOS
tool descriptions differ), and add `envs/desktop-*-macos-cmux` and `tasks/macos-cmux-*.json` to `overlay.py` the way
the Linux ones are made (from the port's `macos-agent-desktop-*` files).

## Run the bench with it

On an amd64 Linux host with Docker and a registry on `localhost:5000` (never on a person's Mac):

```bash
git clone https://github.com/earakely-scale/agentenv-cua-driver-bench port && git -C port checkout f6bf217
python3 overlay.py port --cmux cmux-tui.gz        # the Linux cmux-tui binary, gzipped
cd port
pip install 'agentenv-framework==0.9.1521'
docker run -d -p 5000:5000 public.ecr.aws/docker/library/registry:2
python tools/taskpack.py                          # trycua's task pack (FSL-1.1), fetched, never committed
agent-env run . --task cmux-probe                 # the computer-use conformance probe at full, on cmux's computer
agent-env run . --eval cmux-benchlab              # BenchLab through cmux's tools, no model
agent-env run . --eval cmux-sentinel              # the sentinel and guard on cmux's s02 computer
agent-env run . --eval cmux-bench-v2              # every trial file once (needs [model], below)
```

The driver is a bundle env of the port (`envs/cmux/`), so its computers name it as `driver = "cmux"`. The framework
resolves a computer's `driver` through the bundle's own envs before its aliases, so `--set envs/desktop.driver=cmux`
also works on the port's own computers once the overlay put `envs/cmux/` there. An out-of-tree id such as
`@local/...` names an installed distribution's bundle, not a folder, so the overlay is the way in.

The trials run Claude Code (`claude-code`, the framework's default agent) with no built-in tools but Skill and Read,
trycua's system prompt and limits, as the port's agent-desktop arm runs them. They need a model endpoint serving
Anthropic's Messages API, in `.agentenv/config.toml`:

```toml
[model]
base_url = "https://your-litellm-or-anthropic-compatible-endpoint"
api_key = "env:LITELLM_API_KEY"
default = "anthropic/claude-opus-5-5"
```

`evals/cmux-bench-v2-trials.txt` lists the 90 trials in trycua's schedule; the port's `tools/fleet/` runs such a list
on a fleet, one `agent-env run . --task` per line.

trycua's task pack and the trial files (which quote trycua's prompts) are FSL-1.1: `overlay.py` writes them into the
port's checkout at run time, and none of it belongs in this repository.
