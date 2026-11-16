# Computer-use latency bench

How long each computer-use engine takes per tool call, and for one whole small task, measured the
same way for every engine. `cu_bench.py` is a stdio MCP client (Python 3.9 standard library): it
launches each engine's MCP server, reads its tool catalog, and maps one op set onto it.

| op | what it calls |
|---|---|
| `list_apps` | `list_apps` (else `list_windows`) |
| `ax_tree` | the state read with no screenshot: `get_app_state` (`screenshot: false`), `get_window_state`, `get_ui_tree` |
| `screenshot` | `screenshot` when the engine has one, else the state read with a screenshot |
| `click` | `click` on Calculator's `1` button, by the element id the latest state gave |
| `type_text` | `type_text` `5` |
| `press_key` | `press_key` `Escape` |
| e2e | read the window, click clear, read again unless the click returned the state, click 1, 2, multiply, 7, equals, read until the display shows 84 |

Three catalog shapes exist today, picked from the tools an engine lists: `app` (calls name the app),
`window` (a pid and a window id) and `tree` (a window id, JSON tree). A button an engine's state
does not show is pressed with its key instead, and the e2e row says `keys`.

Engines take turns each round, in alternating order. Calculator is relaunched (as the bench's own
child) at the start of each engine's turn and before each e2e sample, and cleared with an untimed
Escape before each action sample. Each engine's server stays up for the run; its start-up time is
reported apart (`startup`).

## Run it

On the fleet, in the bench VM (granted Accessibility, event posting and screen capture; see
`../cu-driver-eval/README.md`), with the engines the arena assembles:

```
cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
  --script scripts/measure/cu-driver-bench.sh --ref SHA --timeout 7200 \
  --artifact artifacts/cu-driver-eval.tgz \
  --arg=suite=latency --arg=arms=cmux-cua,cu-fast,cu-rewrite --arg=reps=15 --arg=budget_s=7200
cmux-ci artifact STEP_ID cu-driver-eval.tgz
```

`arms=` names arena arms (`cmux-cua` is the previous engine; `cu-fast` and `cu-rewrite` are built
at the commits `pins.json` `arena.engines` names, or `cu_fast=SHA` / `cu_rewrite=SHA`). `reps=` is
the number of rounds; each round takes 2 samples of every op and 1 e2e loop per engine.

On a Mac whose terminal already holds those grants, any MCP server works:

```
python3 scripts/measure/cu-bench/cu_bench.py run --out /tmp/cu-bench \
  --server "fast=/path/to/cmux-cu-service mcp --app /path/to/cmux CU Engine.app" --rounds 10
```

## Output

`artifacts/cu-driver-eval/cu-bench/`: `cu-bench.json` (schema in the `cu_bench.py` docstring),
`summary.md` (median / p95 ms per op and engine), `samples.jsonl` (every call) and
`first/ENGINE-OP.txt` (each op's first answer, images left out, to check a mapping).
`cu_bench.py summary DIR` prints the table again.

## Test

`python3 scripts/measure/cu-bench/test_cu_bench.py` needs no GUI: it checks the stats and parsers
and runs the whole bench against fake engines of the `app` and `tree` shapes that play Calculator.
