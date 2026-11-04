// l10n-allow-file: test fixture prompts and harness errors, not shipped UI.
// A running turn whose harness retries a failed model request (acpmux `turn_retrying`): its live
// line says the model cannot be reached, with the retry's count and error, never "Thinking" and
// no clock (Leo, 2026-11-03, on "Thinking 7m 49s" while Claude Code retried a gateway that was down).
import { expect, test } from "bun:test";
import { renderToStaticMarkup as renderMarkup } from "react-dom/server";
import { TURN_RETRY, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
import retryEntry from "../src/agent-session/acpmux/conversation/TurnRetry.gallery";

import type { ReactNode } from "react";
import { StatusVerbContext } from "../src/agent-session/acpmux/statusVerbs";

// These assertions cover turn state and time, independently of decorative verb rotation.
const renderToStaticMarkup = (node: ReactNode) =>
  renderMarkup(
    <StatusVerbContext.Provider value={{ mode: "thinking", verbs: ["Thinking"] }}>{node}</StatusVerbContext.Provider>,
  );

const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x27;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
const liveLine = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { working: true, liveRuns: true, lineBelow: true }).at(-1)!;
const drawn = (line: AcpmuxRow, now: number) =>
  renderToStaticMarkup(
    <Thinking since={line.at} now={() => now} turnTotal={line.turnTotal} retry={line.retry} below />,
  );

const snapshotRows = (name: string) => (retryEntry.variants[name] as { snapshot: { rows: AcpmuxRow[] } }).snapshot.rows;

test("a turn whose model the harness cannot reach says so, with its count and error and no clock", () => {
  const line = liveLine(snapshotRows("retrying-with-error"));
  expect(line.kind).toBe(THINKING);
  expect(line.retry).toEqual({ attempt: 7, maxRetries: 10, errorStatus: 503, error: "server_error" });
  const html = drawn(line, line.at + 469_000);
  expect(words(html)).toBe("Can't reach the model · retrying (7 of 10) · 503 server error");
  // Calm: no sweep and no ticking time on the line.
  expect(html).not.toContain("is-shimmer");
  expect(html).not.toContain("cv-worked__time");
  // The same box as the Thinking line it replaces, so nothing moves.
  expect(html).toContain('class="cv-worked cv-worked--live is-below"');
});

test("the line reads Thinking again once the model answers, timed without the retries", () => {
  const rows = snapshotRows("retrying");
  const user = rows[0]!;
  const heard: AcpmuxRow[] = [
    user,
    { id: TURN_RETRY, version: 2, at: user.at + 25_000, kind: "typing", retriedMs: 440_000 },
  ];
  const line = liveLine(heard);
  expect(line.retry).toBeUndefined();
  expect(words(drawn(line, user.at + 469_000))).toBe("Thinking 29s");
});

test("a busy model says it is busy, not unreachable", () => {
  expect(words(drawn(liveLine(snapshotRows("retrying-busy")), Date.now()))).toBe(
    "The model is busy · retrying (2 of 10) · 529 overloaded error",
  );
});
