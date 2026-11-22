// Sent Prompt Placement `top` (conversation/sendSeat.ts; Leo 2026-11-22: "the wider sweeping situation with
// having there be a bunch of extra space at the bottom is not something we need to emulate (other than our
// claude code customization emulation repo)"). The seat binds to the prompt sent after `before`, finds it again
// when rows above it come or go, holds the end at its top plus a view, and the setting defaults to today's.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { SEAT_TOP_PX, seatEnd, seatIndex, type SendSeat } from "../src/agent-session/acpmux/conversation/sendSeat";
import { SEND_PLACEMENT_KEY, sendPlacement, setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, kind: "user" | "assistant" | "thinking" = "assistant"): AcpmuxRow =>
  ({ id, kind, text: id, version: 1, at: 0 }) as AcpmuxRow;
const noLine = () => false;

describe("send seat", () => {
  test("binds to the first prompt newer than the one there was at the send, not before it lands", () => {
    const rows = [row("u1", "user"), row("a1")];
    const seat: SendSeat = { sessionId: "s", before: "u1" };
    expect(seatIndex(seat, rows, noLine)).toBeUndefined();
    expect(seat.id).toBeUndefined();
    const landed = [...rows, row("u2", "user"), row("t", "thinking")];
    expect(seatIndex(seat, landed, noLine)).toBe(2);
    expect(seat.id).toBe("u2");
    // The same rows again (a render React threw away and ran again): the same answer.
    expect(seatIndex(seat, landed, noLine)).toBe(2);
  });

  test("a chat with no prompt yet binds the first one sent", () => {
    const seat: SendSeat = { sessionId: "s", before: undefined };
    expect(seatIndex(seat, [], noLine)).toBeUndefined();
    expect(seatIndex(seat, [row("u1", "user")], noLine)).toBe(0);
  });

  test("finds its prompt again when older history lands above it, and lets go of one that left", () => {
    const seat: SendSeat = { sessionId: "s", before: "u1" };
    const rows = [row("u1", "user"), row("u2", "user"), row("a2")];
    expect(seatIndex(seat, rows, noLine)).toBe(1);
    const older = [row("u0", "user"), row("a0"), ...rows];
    expect(seatIndex(seat, older, noLine)).toBe(3);
    expect(seatIndex(seat, [row("u1", "user")], noLine)).toBeUndefined();
    expect(seat.lost).toBe(true);
    // Lost stays lost: no scan of the rows at every pass after.
    expect(seatIndex(seat, older, noLine)).toBeUndefined();
  });

  test("a line row (a user notice) is no prompt", () => {
    const seat: SendSeat = { sessionId: "s", before: "u1" };
    const rows = [row("u1", "user"), row("line", "user")];
    expect(seatIndex(seat, rows, (r) => r.id === "line")).toBeUndefined();
  });

  test("holds the end at the prompt's top less 20 px plus a view (Claude's topOffsetPx)", () => {
    expect(SEAT_TOP_PX).toBe(20);
    expect(seatEnd(1000, 600)).toBe(1000 - 20 + 600);
    expect(seatEnd(10, 600)).toBe(600);
    expect(seatEnd(undefined, 600)).toBe(0);
    expect(seatEnd(1000, 0)).toBe(0);
  });

  test("the setting defaults to today's follow; top only when set", () => {
    setChatDisplay({});
    expect(sendPlacement()).toBe("latest");
    setChatDisplay({ [SEND_PLACEMENT_KEY]: "nonsense" });
    expect(sendPlacement()).toBe("latest");
    setChatDisplay({ [SEND_PLACEMENT_KEY]: "top" });
    expect(sendPlacement()).toBe("top");
    setChatDisplay({});
  });

  test("the schema row's default is latest, and only the Claude Code look sets top", () => {
    const root = path.join(import.meta.dir, "../..");
    const source = JSON.parse(
      fs.readFileSync(path.join(root, "schemas/settings/source/agent-pane-display.json"), "utf8"),
    ) as { lists: { rows: { key: string; default: unknown; choices?: { value: string }[] }[] }[] };
    const rowSpec = source.lists.flatMap((list) => list.rows).find((spec) => spec.key === SEND_PLACEMENT_KEY);
    expect(rowSpec?.default).toBe("latest");
    expect(rowSpec?.choices?.map((choice) => choice.value)).toEqual(["latest", "top"]);
    for (const part of ["transcript", "whole"])
      for (const file of ["cmux-setup.json", "profile.json"]) {
        const look = JSON.parse(fs.readFileSync(path.join(root, "examples/looks/claude-code", part, file), "utf8")) as {
          settings: Record<string, unknown>;
        };
        expect(look.settings[SEND_PLACEMENT_KEY]).toBe("top");
      }
  });
});
