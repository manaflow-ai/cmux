// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A question the agent asked the person (a tagged ask, nextStepAsk.ts) stays a question until the
// person answers it, whatever turns come after. Leo, 2026-11-06: "some sort of other message came
// in, like from another, another instance ... It stopped being rendered. But we want to keep these
// things rendered, and perhaps persistent at the bottom, or perhaps at the side."
//
// Before: another agent's message that opened the next turn counted as "nothing can answer it"
// (turns.ts `shapeTurn`), so the card went back into the prose, with no buttons left to answer.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { answerThrough } from "./turnActions";
import { NEXT_STEP, turnView, turnViewFrom, waitingAsks } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
const prompt = (id: string, text: string) => row(id, "user", { text });
const reply = (id: string, text: string) => row(id, "assistant", { text });
const done = (id: string) => row(id, "turnSummary", { status: "completed" });
/// Another agent's message, as direct.ts draws an inbox notice or a relayed send.
const inbound = (id: string, text: string) =>
  row(id, "user", {
    text,
    untyped: true,
    incoming: { kind: "message", message: { name: "lane-a", text, raw: text } },
  } as Partial<AcpmuxRow>);

const ASK = "Checked the lock path.\n\n[taste] Do you mean computer use, still working while the Mac is locked?";
const asked = [prompt("p1", "Why does it stop on lock?"), reply("a1", ASK), done("s1")];
const afterInbound = [...asked, inbound("m1", "Pushed abc123; CI is running."), reply("a2", "Noted."), done("s2")];
const cards = (rows: readonly AcpmuxRow[]) => rows.filter((shown) => shown.kind === NEXT_STEP);

describe("a question to the person after another agent's message", () => {
  test("stays an answerable card once another agent's message opens a new turn", () => {
    const [card] = cards(turnView(afterInbound, new Set()));
    expect(card?.nextStep?.ask.question).toBe("Do you mean computer use, still working while the Mac is locked?");
    expect(card?.nextStep?.answer).toBeUndefined();
    expect(card?.nextStep?.superseded).toBeUndefined();
  });

  test("stays answerable while the inbound turn runs", () => {
    const rows = [...asked, inbound("m1", "Pushed abc123."), reply("a2", "Reading")];
    const [card] = cards(turnView(rows, new Set(), { working: true }));
    expect(card?.nextStep?.answer).toBeUndefined();
  });

  test("the person's answer after the inbound turn settles it", () => {
    const [card] = cards(turnView([...afterInbound, prompt("p2", "Yes")], new Set()));
    expect(card?.nextStep?.answer).toBe("Yes");
  });

  test("a later card from another agent's turn does not take it over", () => {
    const rows = [
      ...afterInbound,
      inbound("m2", "Ready to post the gallery."),
      reply("a3", "[outward] Should I post the gallery?"),
      done("s3"),
    ];
    const [first, second] = cards(turnView(rows, new Set()));
    expect(first?.nextStep?.superseded).toBeUndefined();
    expect(second?.nextStep?.superseded).toBeUndefined();
    // Both wait on the person, oldest first, pinned above the composer.
    expect(waitingAsks(turnViewFrom(rows, new Set())).map((card) => card.nextStep?.ask.question)).toEqual([
      "Do you mean computer use, still working while the Mac is locked?",
    ]);
  });

  test("is listed as waiting once a turn follows it, and no longer once the person speaks", () => {
    // The chat's last word: the card sits right above the composer already.
    expect(waitingAsks(turnViewFrom(asked, new Set()))).toEqual([]);
    const waiting = waitingAsks(turnViewFrom(afterInbound, new Set()));
    expect(waiting.map((card) => card.id)).toEqual([cards(turnView(afterInbound, new Set()))[0]!.id]);
    expect(waitingAsks(turnViewFrom([...afterInbound, prompt("p2", "Something else first")], new Set()))).toEqual([]);
  });

  test("a reload of the same records draws the same waiting card", () => {
    const first = turnViewFrom(afterInbound, new Set());
    const reloaded = turnViewFrom(
      afterInbound.map((r) => ({ ...r })),
      new Set(),
    );
    expect(waitingAsks(reloaded).map((card) => card.nextStep)).toEqual(waitingAsks(first).map((card) => card.nextStep));
  });
});

// Leo, 2026-11-06: "It was about you asking a question to me that had a question-answer response and
// then another message from another agent interrupted you and then there's nothing now." The other
// agent's message steered into the turn that asked, and the agent answered it, so the ask was no
// longer the turn's last words: before, it stayed plain prose, with no card and no buttons.
describe("a question another agent's message cut off inside the same turn", () => {
  /// Another agent's message acpmux steered into the running turn, as direct.ts draws it once read.
  const steer = (id: string, text: string) => ({ ...inbound(id, text), steer: "landed" }) as AcpmuxRow;
  const steered = [
    prompt("p1", "Why does it stop on lock?"),
    reply("a1", ASK),
    steer("m1", "Pushed abc123; CI is running."),
    reply("a2", "Noted, CI is running."),
    done("s1"),
  ];

  test("is an answerable card under the reply that asked it", () => {
    const shown = turnView(steered, new Set());
    const [card] = cards(shown);
    expect(card?.nextStep?.ask.question).toBe("Do you mean computer use, still working while the Mac is locked?");
    expect(card?.nextStep?.answer).toBeUndefined();
    const ids = shown.map((each) => each.id);
    expect(ids.indexOf(card!.id)).toBe(ids.indexOf("a1") + 1);
    // The asking reply drops the ask's lines, which the card draws; the reply to the message stays whole.
    expect(shown.find((each) => each.id === "a1")?.text).toBe("Checked the lock path.");
    expect(shown.find((each) => each.id === "a2")?.text).toBe("Noted, CI is running.");
  });

  test("waits on the person, and their answer settles it", () => {
    expect(
      waitingAsks(turnViewFrom([...steered, inbound("m2", "Green."), reply("a3", "Ok."), done("s2")], new Set())),
    ).toHaveLength(1);
    const [card] = cards(turnView([...steered, prompt("p2", "Yes")], new Set()));
    expect(card?.nextStep?.answer).toBe("Yes");
  });

  test("the person's own steer after it is their reply: no card", () => {
    const rows = [
      prompt("p1", "Why?"),
      reply("a1", ASK),
      { ...prompt("p2", "Not that, the other one"), steer: "landed" } as AcpmuxRow,
      reply("a2", "Ok."),
      done("s1"),
    ];
    expect(cards(turnView(rows, new Set()))).toEqual([]);
  });

  test("an ask the agent's reply to the message ends on is that one's card, not the cut-off one", () => {
    const rows = [
      prompt("p1", "Why?"),
      reply("a1", ASK),
      steer("m1", "Ready to post."),
      reply("a2", "[outward] Should I post the gallery?"),
      done("s1"),
    ];
    expect(cards(turnView(rows, new Set())).map((card) => card.nextStep?.ask.question)).toEqual([
      "Should I post the gallery?",
    ]);
  });

  test("a turn still running draws no card yet", () => {
    const rows = [prompt("p1", "Why?"), reply("a1", ASK), steer("m1", "Pushed."), reply("a2", "Reading")];
    expect(cards(turnView(rows, new Set(), { working: true }))).toEqual([]);
  });
});

describe("the card's answer", () => {
  test("goes as the person's prompt", async () => {
    const sent: unknown[] = [];
    await answerThrough((method, params) => {
      sent.push([method, params]);
      return Promise.resolve();
    })("Yes");
    expect(sent).toEqual([["chat.send", { text: "Yes" }]]);
  });

  test("a send that fails rejects, so the card says so rather than dropping it", async () => {
    const failed = answerThrough(() => Promise.reject(new Error("refused")))("Yes");
    await expect(failed).rejects.toThrow("refused");
  });
});
