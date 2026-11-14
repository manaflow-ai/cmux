# macOS: truth matrix and native fixture

Does a computer-use tool tell the truth about what its actions did? These tools
measure it on macOS, in a disposable Tart guest, with no model.

```
fixtures/macos/main.swift   native AppKit fixture with an oracle (build: fixtures/macos/build.sh)
macos/truthmatrix.py        engine-claim accuracy: claim vs ground truth, per action, bg and fg scenes
macos/truthreport.py        confusion matrices and tables from truth.jsonl
macos/bgmatrix.py           the background matrix (real apps, invariants); truthmatrix reuses its arms and read-backs
macos/aside_arm.py          the Aside arm (one `repl` tool) for both matrices
macos/probe.swift           independent observer: AX, CGWindowList, pointer, front app; scene setup (activate, raise, frame)
macos/gr.sh                 run a command in the guest console user's Aqua session (launchd gui/<uid>)
```

## The fixture

One binary, three bundles (`build.sh`): **CU Eval Fixture** (modes `form`, `lab`),
**Eval Settings** (`settings`, matched by the deny entry `name:Eval Settings`) and
**Person** (`person`). The `form`, `settings` and `person` modes keep the Tk
fixture's state schema, so `cueval` tasks and checks run unchanged; on macOS
`platform_env.start_fixture` uses the native bundles when they are built
(`CUEVAL_MACOS_FIXTURES=DIR`, or `fixtures/macos/build`). `CUEVAL_MACOS_TK=1`
keeps Tk.

`lab` opens four windows: **Truth Form** (text field, secure field, checkbox,
radio group, pop-up, slider, stepper, buttons, tabs, a sheet, a popover, a
context menu, a 100-row table), **Truth Text** (text view), **Truth Canvas** (a
canvas with no AX element, a drag source and a drop target) and **Truth Twin**
(a near-identical small form, for wrong-window detection). Its menu bar has a
**Truth** menu with a key equivalent (cmd-shift-K), a submenu and a disabled item.

The oracle is the app itself:

- `--events FILE` JSONL: one line per state change (`kind: state`, window, element,
  value, `via` = the input that caused it: mouse, key, scroll, or `ax` when there was
  no input event) and per input event received (`kind: input`), each with `t`, the
  wall clock (`time.time()` in the harness);
- `--state FILE` the whole state, rewritten after every change;
- `--sock PATH` `state`, `reset`, `ping` (one line in, one JSON line out).

Frames are window-relative points from the top-left **including the title bar**
(window-screenshot space), plus global screen frames.

## The truth matrix

```
./gr.sh ./cuenv.sh python3 truth/truthmatrix.py --arm cmux-cu --reps 3 --out OUT
python3 macos/truthreport.py --in cmux=OUT/truth.jsonl --in cua=... --out tables/
```

Each cell: reset, arrange the scene (`bg`: the Person app frontmost, key, covering
every target, typing in-process; `fg`: the target app frontmost, its window key),
observe (a screenshot, the tree when the action needs an element), make the scored
action, then poll the ground truth up to `--late` s (3.5) after the tool returned.
Every row has the tool's claim (`confirmed`, `delivered`, `ok`, `no_visible_change`,
`error`, `refused`), the truth (`correct`, `none`, `wrong`, `extra`), the outcome
(TP, FP, FN, TN, SIDE, or `no_action` when no scored action was reached), the effect
time relative to the result, the side effects, and the background invariants.

Never run this on a person's Mac: it opens windows, types and clicks.
