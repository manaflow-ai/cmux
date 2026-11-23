# The test agent has a "surfaces-tour" prompt

Landed in f0bc944f808b (feat-cmux-next), with the chat surface levels (5c5ca6da..d2844e19,
`design/chat-surfaces.md`). User 2026-11-19: "bgs are different, we need to make all bgs
consistent, from first principles".

What changed in acpmux:

- `tests/fake_agent.py`: a new prompt, `surfaces-tour` (a prefix match, before `overloaded:`). One
  turn sends a plan (three entries), a completed `execute` tool call (`tour-run`) with a short text
  output, a completed `edit` tool call (`tour-edit`) whose diff makes a new 55-line `PROPOSAL.md` in
  the agent's working directory (the path only; the agent writes no file), and one reply with
  inline code, a fenced code block and a table, then `end_turn`.
- No other prompt, reply or exit path changed. No Rust test sends the prompt.

Who uses it: `scripts/cmux-next/chat-surfaces-shots.py` (run on a fleet Mac by
`scripts/measure/chat-surfaces.sh`) makes one chat on the test agent, sends `surfaces-tour` and then
`overloaded: now` (the turn error card), and shoots the window in each window style, dark and light;
with `--hovers` it also shoots each moved hover under a real pointer.

Keep in mind: a change to the prefix match order in `fake_agent.py`, or a prompt that starts with
`surfaces-tour`, changes what the shots show. Tell the chat surfaces owner (design/chat-surfaces.md)
before you rename or remove it.
