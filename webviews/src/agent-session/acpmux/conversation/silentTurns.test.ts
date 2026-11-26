// A streamed record reuses the last split (silentTurns.ts `splitSilentTurns`): every step's split
// must equal the one read from every row (`splitSilentTurnsFull`).
import { describe, expect, test } from "bun:test";
import { activity, assistant, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { splitSilentTurns, splitSilentTurnsFull } from "./silentTurns";

const check = (command: string) =>
  tool(command, "execute", "completed", { command, output: "ok", description: command });

const quiet = (id: string, minutes: number): AcpmuxRow[] => [
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: { id, trigger: "system", running: false, quiet: true, reason: "result", hasRows: true },
  } as Partial<AcpmuxRow>),
  activity([check(`gh pr checks ${id}`)], minutes - 0.01, { id: `${id}-work`, inBackground: id }),
];

const inbox = (id: string, minutes: number): AcpmuxRow[] => [
  user("notice", minutes, {
    id,
    incoming: {
      kind: "inbox",
      notice: { threads: [{ threadId: `t:${id}`, label: "x", from: ["q"], count: 1, promptIds: [`${id}-p`] }] },
    },
  } as Partial<AcpmuxRow>),
  activity([check(`gh run list ${id}`)], minutes - 0.01, { id: `${id}-work` }),
  summary(minutes - 0.02, { id: `${id}-footer`, status: "completed", durationMs: 1_000 }),
];

const history = (turns: number): AcpmuxRow[] =>
  Array.from({ length: turns }, (_, at) => {
    const minutes = 600 - at;
    return [
      user(`ask ${at}`, minutes, { id: `ask-${at}` }),
      assistant(`reply ${at}`, minutes - 0.1, { id: `reply-${at}` }),
      ...(at % 3 === 0 ? quiet(`bg-${at}`, minutes - 0.2) : []),
      ...(at % 4 === 1 ? inbox(`in-${at}`, minutes - 0.3) : []),
    ];
  }).flat();

const same = (rows: AcpmuxRow[], working: boolean) =>
  expect(splitSilentTurns(rows, working)).toEqual(splitSilentTurnsFull(rows, working));

describe("splitSilentTurns reuse", () => {
  test("a streamed running turn splits as a full read does, at every step", () => {
    const base = [...history(40), user("go on", 1, { id: "live-ask" })];
    expect(splitSilentTurnsFull(base, true).silent.length).toBeGreaterThan(0);
    let rows = base;
    same(rows, true);
    let text = "";
    for (let step = 0; step < 30; step += 1) {
      text += `w${step} `;
      const reply = assistant(text, 0.5, { id: "live-reply" });
      rows = step === 0 ? [...rows, reply] : [...rows.slice(0, -1), reply];
      same(rows, true);
    }
    // A thought, then a call appended, then the call's end replacing it.
    rows = [...rows, activity([{ ...thought("hmm"), id: "th" }], 0.4, { id: "live-think" })];
    same(rows, true);
    rows = [...rows, activity([check("ls")], 0.3, { id: "live-call" })];
    same(rows, true);
    rows = [...rows.slice(0, -1), activity([check("ls"), check("pwd")], 0.3, { id: "live-call" })];
    same(rows, true);
  });

  test("the reused split keeps the silent turns' list", () => {
    const base = [...history(12), user("go on", 1, { id: "live-ask" })];
    const first = splitSilentTurns(base, true);
    const next = splitSilentTurns([...base, assistant("a", 0.5, { id: "r" })], true);
    expect(next.silent).toBe(first.silent);
  });

  test("a prompt, a background turn, its rows or the turn's end read every row again", () => {
    const base = [...history(12), user("go on", 1, { id: "live-ask" }), assistant("a", 0.5, { id: "r" })];
    same(base, true);
    // An inbox notice opens a new turn after the running one.
    same([...base, ...inbox("late", 0.4)], true);
    same(base, true);
    // A background turn line and its work land at the tail.
    same([...base, ...quiet("late-bg", 0.3)], true);
    same(base, true);
    // The turn ends: the last turn may now go to the hat.
    same(base, false);
    // A row removed, then a row changed mid-history.
    same(base.slice(0, -1), true);
    same(
      base.map((row) => (row.id === "reply-3" ? { ...row, text: "edited" } : row)),
      true,
    );
  });

  test("an agent's ended turn at the tail goes to the hat once the chat stops working", () => {
    const base = [...history(4), ...inbox("tail", 1)];
    same(base, true);
    same(base, false);
    expect(splitSilentTurns(base, false).silent.map((turn) => turn.id)).toContain("tail");
  });
});
