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
const liveLine = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true }).at(-1)!;
const drawn = (line: AcpmuxRow, now: number) =>
  renderToStaticMarkup(
    <Thinking
      since={line.at}
      now={() => now}
      turnTotal={line.turnTotal}
      retry={line.retry}
      retryAt={line.retryAt}
      below
    />,
  );

const snapshotRows = (name: string) => (retryEntry.variants[name] as { snapshot: { rows: AcpmuxRow[] } }).snapshot.rows;

test("a turn whose model the harness cannot reach says so in one short line, its count and error in the tooltip", () => {
  const line = liveLine(snapshotRows("retrying-with-error"));
  expect(line.kind).toBe(THINKING);
  expect(line.retry).toEqual({ attempt: 1, maxRetries: 14, errorStatus: 502, error: "server_error" });
  const html = drawn(line, line.at + 469_000);
  // Leo, 2026-11-26, flagged "Can't reach ... · retrying (1 of 14) · retrying now · 502 ser..." as
  // very bad.
  expect(words(html)).toBe("Model API unavailable, retrying…");
  expect(html).toContain('title="retrying (1 of 14) · 502 server error"');
  // No ticking time on the line; its words shimmer as every status in the live spot does (Leo,
  // 2026-11-22: "all in the "thinking" spot should glimmer like that").
  expect(html).toContain('class="cv-thinking is-shimmer cv-retrying"');
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

test("a busy model waits for capacity, its count and 529 only in the tooltip", () => {
  const html = drawn(liveLine(snapshotRows("retrying-busy")), Date.now());
  expect(words(html)).toBe("Waiting for capacity");
  expect(html).toContain('title="retrying (2 of 10) · 529 overloaded error"');
});

test("a retry that goes through within a few seconds draws nothing new", () => {
  const line = liveLine(snapshotRows("retrying-with-error"));
  // Three seconds into the retries the line still reads as it did; past the bound it says so.
  expect(words(drawn(line, line.retryAt! + 3_000))).not.toContain("unavailable");
  expect(words(drawn(line, line.retryAt! + 10_000))).toBe("Model API unavailable, retrying…");
});
