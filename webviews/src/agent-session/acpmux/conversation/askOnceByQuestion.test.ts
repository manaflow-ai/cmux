// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// One card per ask, also when the agent asks the same question again (Leo, 2026-11-19, with the same
// [trust] question drawn as two stacked "Needs your input" cards: "odd looking"). A coordinator woken
// by another agent's message asks its open question again in the new turn; each turn's card had its
// own key (its turn's time), so the pinned stack drew one card per turn that asked it.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnViewFrom, waitingAsks } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
const prompt = (id: string, text: string) => row(id, "user", { text });
const reply = (id: string, text: string) => row(id, "assistant", { text });
const done = (id: string) => row(id, "turnSummary", { status: "completed" });
const inbound = (id: string, text: string) =>
  row(id, "user", {
    text,
    untyped: true,
    incoming: { kind: "message", message: { name: "lane-a", text, raw: text } },
  } as Partial<AcpmuxRow>);
/// The agent's wrap-up call (wrapUp.ts), finished.
const wrapUp = (id: string, ask: string) =>
  row(id, "activity", {
    items: [
      {
        id: `${id}-call`,
        tool: {
          id: `${id}-call`,
          title: "mcp__acpmux__wrap_up",
          kind: "other",
          status: "completed",
          inputSummary: JSON.stringify({ recap: "Merged #1.", ask, actions: ["Trust it", "Not now"] }),
        },
      },
    ],
  } as unknown as Partial<AcpmuxRow>);

const ASK = "[outward] Should I post the gallery to the PR?";
const questions = (rows: readonly AcpmuxRow[]) =>
  waitingAsks(turnViewFrom(rows, new Set())).map((card) => card.nextStep?.ask.question);

describe("the same question asked in two turns", () => {
  test("pins one card, the newest", () => {
    const rows = [
      prompt("p1", "Gallery?"),
      reply("a1", ASK),
      done("s1"),
      inbound("m1", "CI green."),
      reply("a2", `CI is green.\n\n${ASK}`),
      done("s2"),
      inbound("m2", "Nightly cut."),
      reply("a3", "Noted."),
      done("s3"),
    ];
    const pinned = waitingAsks(turnViewFrom(rows, new Set()));
    expect(pinned.map((card) => card.nextStep?.ask.question)).toEqual(["Should I post the gallery to the PR?"]);
    expect(pinned[0]!.at).toBeGreaterThan(rows[1]!.at);
  });

  test("pins none while the newest asking is the chat's last word", () => {
    const rows = [
      prompt("p1", "Gallery?"),
      reply("a1", ASK),
      done("s1"),
      inbound("m1", "CI green."),
      reply("a2", ASK),
      done("s2"),
    ];
    expect(questions(rows)).toEqual([]);
  });

  test("a wrap-up asked again pins once", () => {
    const TRUST = "[trust] Trust ~/fun/cmux for the new sub-session?";
    const rows = [
      prompt("p1", "Start the lane."),
      reply("a1", "Started."),
      wrapUp("w1", TRUST),
      done("s1"),
      inbound("m1", "Still waiting."),
      reply("a2", "Still waiting on you."),
      wrapUp("w2", TRUST),
      done("s2"),
      inbound("m2", "ping"),
      reply("a3", "Noted."),
      done("s3"),
    ];
    expect(questions(rows)).toHaveLength(1);
  });

  test("two different questions both stay", () => {
    const rows = [
      prompt("p1", "Gallery?"),
      reply("a1", ASK),
      done("s1"),
      inbound("m1", "CI green."),
      reply("a2", "[taste] Is 32 px right for the live line?"),
      done("s2"),
      inbound("m2", "Nightly cut."),
      reply("a3", "Noted."),
      done("s3"),
    ];
    expect(questions(rows)).toEqual(["Should I post the gallery to the PR?", "Is 32 px right for the live line?"]);
  });
});
