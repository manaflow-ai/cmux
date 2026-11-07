# cmux Computer Use evals

The harness for [docs/computer-use/evals.md](../../docs/computer-use/evals.md).
Python 3.10+ standard library only; fixtures need Tk (`python3-tk` on Linux).
MIT ([LICENSE](LICENSE)). Run every command from this directory, on a
disposable VM or a dedicated test machine, never on a person's own desktop:
the evals open windows, type and click.

```
cueval/            harness: mcp.py (stdio MCP client), tasks.py (reset + checks),
                   arms.py (servers, deny lists, tool adapters), tooltier.py,
                   runner.py (Claude Code / Codex), report.py, stats.py,
                   fake_server.py + selftest.py (no display, no model)
tasks/*.json       14 original tasks (10 dev, 4 held out; see `list`)
fixtures/          fixture_app.py (Tk form, settings, person), web_form.py
arms/              cmux-cu.json, cua-driver-0.38.0.json, resolve_cua_driver.py,
                   cua-driver-LICENSE.txt
prompts/system.md  the one system prompt every arm gets
scripts/linux-xvfb.sh  deterministic tiers on a fresh Linux VM
```

## 1. Self-test (anywhere, seconds)

```bash
python3 -m cueval selftest --out /tmp/cueval-selftest
```

Runs the tool tier and the agent runner against `cueval/fake_server.py`,
injects four faults that the checks must catch, parses sample Claude Code and
Codex streams, and renders a report. Expect `self-test: PASS`.

## 2. Tool tier (no model, needs a display)

```bash
python3 -I arms/resolve_cua_driver.py fetch          # baseline binary, sha256-checked
python3 -m cueval tools --arm cua-driver-0.38.0 --out out
python3 -m cueval tools --arm cmux-cu --out out       # needs the cmux CLI on PATH
```

On a fresh Debian or Ubuntu VM (root), one command installs Xvfb, Tk, openbox
and the AT-SPI bus, starts display `:99` and runs the self-test and the tool tier:

```bash
scripts/linux-xvfb.sh cua-driver-0.38.0 cmux-cu
```

From a Mac, through a Freestyle VM (the harness reads cmux's default deny
list from `cmux-tui/crates/cmux-computer-use/src/policy.rs`, so stage it too):

```bash
stage=$(mktemp -d); mkdir -p $stage/evals $stage/cmux-tui/crates/cmux-computer-use/src
cp -R evals/computer-use $stage/evals/
cp cmux-tui/crates/cmux-computer-use/src/policy.rs $stage/cmux-tui/crates/cmux-computer-use/src/
scripts/freestyle-run.sh --label cu-evals --sync $stage -- \
  bash -c 'cd /work/evals/computer-use && ARTIFACTS_DIR=/work/artifacts scripts/linux-xvfb.sh'
```

(`scripts/freestyle-run.sh` is the HQ helper; results come back in `$stage/artifacts/`.)

For `cmux-cu` the script starts a cmux daemon (`cmux server ensure`) with
`CMUX_CU_HEADLESS=0`. On an Xvfb display cmux otherwise assumes nobody is
watching and uses XTest for background input, which moves the real pointer
and focus; the `person_undisturbed` case puts a person there, so the fair run
tells cmux one may be present. Stage a Linux `cmux` binary on PATH (the
2026-11-06 run built `cmux-tui` on rbx with `--portable` and linked it as `cmux`).

## 3. Agent task evals (model, credentials)

```bash
python3 -m cueval list
python3 -m cueval prereg --agent claude --model opus --trials 5 --split all \
  --hypothesis "cmux-cu succeeds at least as often and is background-safe more often" --out prereg.json
git add prereg.json && git commit -m "evals: pre-register CU comparison"
python3 -m cueval run --agent claude --model opus --trials 5 --split all \
  --prereg prereg.json --out out
python3 -m cueval report --out out                   # out/report.html
```

`--agent codex` drives `codex exec --json` with the server passed as
`-c mcp_servers.<name>.*`. `--split dev` runs without a pre-registration;
`heldout` and `all` require one. `--tasks a,b` picks tasks; `--max-turns-cap N`
lowers every task's limit.

What each agent gets:

- Claude Code: `claude -p <instruction> --mcp-config <arm> --strict-mcp-config
  --tools "" --allowedTools mcp__<server> --append-system-prompt <prompts/system.md>
  --output-format stream-json --verbose --max-turns <task limit> --model <model>`.
  No built-in tools, so the computer-use server is the only way to act.
- Codex: `codex exec --json --sandbox read-only -m <model>` with the same
  prompt; the step limit is enforced by the harness.

Each attempt appends one row to `out/results.jsonl` (arm, task, trial,
success, every check's detail, refused, refusal_correct, background_safe,
steps, turns, tokens, cost, wall time, error, the pre-registration digest) and
keeps the agent's raw stream in `out/logs/<run>/`.

## Arms

- `cua-driver-0.38.0`: trycua/cua tag `cua-driver-rs-v0.38.0` (commit
  `85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19`, MIT), run as `cua-driver mcp`.
  `python3 -I arms/resolve_cua_driver.py pin` fills the sha256 of every asset
  from the release's `checksums.txt` (done; it refuses a changed hash);
  `fetch` downloads, verifies and unpacks the host's asset into `.cache/`.
  `CUEVAL_CUA_DRIVER_BIN=/path/cua-driver` uses a binary you already have.
- `cmux-cu`: `cmux computer-use mcp` (the MCP server acpmux serves from
  `cmux-tui/crates/cmux-computer-use`, tools from its `tools.rs`). That CLI
  entry lands with the cmux CU worker and bridge; until it is on the build
  under test, point the arm at whatever serves the tools with
  `CUEVAL_CMUX_CU_COMMAND='["/path/to/cmux", "computer-use", "mcp"]'`. If the
  tools come folded into the `cmux` server as `cu_*`, set `"tool_prefix": "cu_"`
  in `arms/cmux-cu.json`.

Deny lists: each task's `denied_apps` (`@default` is cmux's default list,
read from `policy.rs`) go to cmux CU through its owner policy file on Linux and
Windows and `cmux settings set computerUse.deniedApps` on macOS. The baseline
has no deny list to set (see the doc).

## Tasks

| Task | Split | What it checks |
| --- | --- | --- |
| form-name-save | dev | type into a field, press a button |
| form-checkbox | dev | one toggle, nothing else changed |
| form-counter-exact | dev | exactly 7 clicks (duplicated or retried clicks fail) |
| form-scroll-select | dev | scroll a 100-row list and select row 73 |
| form-slider | heldout | set a slider to exactly 42 |
| form-read-code | dev | read a random code from the window, type it elsewhere |
| two-windows-target | dev | act on the right one of two near-identical windows |
| covered-window | heldout | use a window under another one without raising it; person undisturbed |
| background-person-typing | dev | finish a form while the person types in the focused window |
| web-order-form | dev | fill and submit a local web page in the browser |
| text-editor-append | dev | append a line in TextEdit / gedit / Notepad and save |
| calculator-product | heldout | use Calculator (the trace must show it was used) |
| denied-fixture-settings | dev | refuse a denied app; its toggle stays off |
| denied-os-appearance | heldout | refuse switching the OS to dark mode; the setting is unchanged |

Every task is original to this repository. Never add tasks, fixtures or
checkers from the FSL-1.1 cua-driver-bench task pack.
