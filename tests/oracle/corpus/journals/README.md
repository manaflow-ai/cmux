# tests/oracle/corpus/journals

Saved input journals for the oracle's `journals` suite ([p15-oracle spec](../../../../plans/cmux-next/chrome-parity/p15-oracle.md),
section 3D, task 104). The suite is differential: there is no reviewed baseline. Two builds replay the same
journals with `OracleReplay`, and `diff.py` compares the two runs.

| Path | Contents |
| --- | --- |
| `<suite>/<case>.jsonl` | The journal the app recorded during an oracle corpus case. `driver_app.py` writes it to `<run out>/journals/` at the end of each case. |
| `handwritten/*.jsonl` | Attach journals written by hand from `TerminalAttachMachine`'s rules. Each record has the phase the machine reaches. |

A journal has a `cmux-input-journal-v1` header line (`source` is the case and `sha` the app commit), then
one `InputJournalEntry` per line, as `debug.journal` returns it. The files are `.jsonl`, so `oracle.py`
does not load them as cases. A journal has no typed text: key records keep only key classes, unless a debug
build was started with `CMUX_NEXT_INPUT_JOURNAL_CHARACTERS=1`. Do not save a journal from such a launch.

## Add journals

Run the corpus with the app driver. Then copy the journals of the cases to keep:

```
cp -R OUT/journals/actions tests/oracle/corpus/journals/
```

## Replay

```
cd Packages/macOS/CmuxNext
swift run OracleReplay --out /tmp/o/journals-HEAD --sha HEAD_SHA ../../../tests/oracle/corpus/journals
python3 -I ../../../scripts/cmux-next/oracle/diff.py /tmp/o/journals-BASE /tmp/o/journals-HEAD
```

`OracleReplay` replays each journal with `InputReplay(entries).run()`, the same call that `debug.replay`
makes. `--replay-json JOURNAL` prints the result as `debug.replay` returns it. `--out` writes
`receipt.json` and `checkpoints.jsonl` (the run format of `diff.py`) and `divergence.json`. The last file
compares the recording (side a) with the replay (side b) and gives the first divergence of each journal.
The exit status is 0 when every replay equals its recording, 1 when a replay is different, and 2 for bad
input.

Focus records replay only after the window's first `focusCheckpoint`, and attach records only
after the terminal's `start`. The result counts the records it skipped.
