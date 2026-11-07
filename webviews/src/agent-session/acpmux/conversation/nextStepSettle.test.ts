// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A next-step card (NextStepCard.tsx) stays answerable after the person sends another prompt, until
// a prompt picks one of its answers or a later turn ends on a card of its own (turns.ts
// `settleNextSteps`). Leo, 2026-11-05, on Claude desktop's next-step box: "after i sent a prompt
// icouldn't select the thing... we can make a better thing in cmux-next for y'all to call".
//
// Before: the first prompt after the card folded it, its first line read as the answer, and the
// buttons went away.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { NEXT_STEP, turnView, turnViewFrom } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
const prompt = (id: string, text: string) => row(id, "user", { text });
const reply = (id: string, text: string) => row(id, "assistant", { text });
const done = (id: string) => row(id, "turnSummary", { status: "completed" });

const ASK = "Built both looks.\n\n[taste] Which look should ship?\n- Box\n- Inline";
const asked = [prompt("p1", "Build the card"), reply("a1", ASK), done("s1")];
const cards = (rows: readonly AcpmuxRow[]) => rows.filter((shown) => shown.kind === NEXT_STEP);

describe("a next-step card after another prompt", () => {
  test("stays answerable while the person sends something else", () => {
    const rows = [...asked, prompt("p2", "Also fix the colour first"), reply("a2", "Fixed."), done("s2")];
    const [card] = cards(turnView(rows, new Set()));
    expect(card?.nextStep).toEqual({ ask: expect.objectContaining({ question: "Which look should ship?" }) });
  });

  test("stays answerable while the next turn runs", () => {
    const rows = [...asked, prompt("p2", "Also fix the colour first"), reply("a2", "Fixing")];
    const [card] = cards(turnView(rows, new Set(), { working: true }));
    expect(card?.nextStep?.answer).toBeUndefined();
    expect(card?.nextStep?.superseded).toBeUndefined();
  });

  test("shows the answer a later prompt picked", () => {
    const rows = [...asked, prompt("p2", "Also fix the colour first"), reply("a2", "Fixed."), done("s2")];
    const [card] = cards(turnView([...rows, prompt("p3", "inline")], new Set()));
    expect(card?.nextStep?.answer).toBe("Inline");
    expect(card?.nextStep?.superseded).toBeUndefined();
  });

  test("a prompt that failed to send leaves it answerable", () => {
    const rows = [...asked, row("p2", "user", { text: "Inline", failed: true })];
    expect(cards(turnView(rows, new Set()))[0]?.nextStep?.answer).toBeUndefined();
  });

  test("folds once a later turn ends on a card of its own, showing what the person said", () => {
    const rows = [
      ...asked,
      prompt("p2", "Neither, try chips\nand smaller"),
      reply("a2", "Chips it is.\n\n[outward] Should I post the gallery?"),
      done("s2"),
    ];
    const [first, second] = cards(turnView(rows, new Set()));
    expect(first?.nextStep).toMatchObject({ superseded: true, answer: "Neither, try chips" });
    expect(second?.nextStep?.answer).toBeUndefined();
    expect(second?.nextStep?.superseded).toBeUndefined();
  });

  test("settles a reused card when a later card supersedes it, and its row counts as changed", () => {
    const before = [...asked, prompt("p2", "Also fix the colour first"), reply("a2", "Fixed."), done("s2")];
    const first = turnViewFrom(before, new Set());
    const live = cards(first.rows)[0]!;
    const later = [...before, prompt("p3", "Go on"), reply("a3", "[outward] Should I post it?"), done("s3")];
    const next = turnViewFrom(later, new Set(), {}, first);
    const settled = cards(next.rows)[0]!;
    expect(settled.nextStep?.superseded).toBe(true);
    expect(settled.version).not.toBe(live.version);
    expect(next.reusedRows ?? 0).toBeLessThanOrEqual(next.rows.indexOf(settled));
    // The same view again keeps the settled row, so its memo and height cache keep it.
    expect(cards(turnViewFrom(later, new Set()).rows)[0]).toBe(settled);
  });
});
