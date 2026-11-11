// l10n-allow-file: claim fixtures, not shipped UI.
// A turn's `claim_checks` (acpmux hub/claim_check.rs) mark its last reply's phrases: green when a run
// backs the claim, red when it failed or none ran, and nothing for a claim the reply does not hold.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./conversation/Markdown";
import { splitClaims } from "./conversation/claimMarks";
import { TurnActionsContext } from "./conversation/turnActions";
import { readClaims } from "./direct";
import type { ClaimCheck } from "./model";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

const backed: ClaimCheck = {
  text: "All tests pass",
  kind: "tests",
  verdict: "backed",
  toolCallId: "t1",
  command: "cargo test",
};
const failed: ClaimCheck = {
  text: "the build succeeds",
  kind: "build",
  verdict: "failed",
  toolCallId: "b1",
  command: "bun run build",
};
const none: ClaimCheck = { text: "lint is clean", kind: "lint", verdict: "none" };

test("splitClaims cuts prose at each phrase, in reading order", () => {
  expect(splitClaims("Done. All tests pass and the build succeeds.", [failed, backed])).toEqual([
    "Done. ",
    { claim: backed, text: "All tests pass" },
    " and ",
    { claim: failed, text: "the build succeeds" },
    ".",
  ]);
  expect(splitClaims("Nothing to see.", [backed])).toEqual(["Nothing to see."]);
  expect(splitClaims("All tests pass", undefined)).toEqual(["All tests pass"]);
});

test("readClaims draws only the kinds and verdicts it knows", () => {
  expect(
    readClaims([
      { text: "All tests pass", kind: "tests", verdict: "backed", toolCallId: "t1", command: "cargo test" },
      { text: "Coverage is 100%", kind: "coverage", verdict: "backed" },
      { text: "lint is clean", kind: "lint", verdict: "maybe" },
      { text: "", kind: "tests", verdict: "none" },
      null,
    ]),
  ).toEqual([backed]);
});

test("a reply draws each verdict's mark, and a run's mark is a button only with somewhere to go", () => {
  const html = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <Markdown claims={[backed, failed, none]}>{"All tests pass, the build succeeds, and lint is clean."}</Markdown>
    </TurnActionsContext.Provider>,
  );
  expect(html).toContain('data-claim-verdict="backed"');
  expect(html).toContain('data-claim-verdict="failed"');
  expect(html).toContain('data-claim-verdict="none"');
  // Inline links that wrap as text, never atomic <button> boxes.
  expect(html).not.toContain("<button");
  expect(html.match(/<a [^>]*cv-claim/g)?.length).toBe(2);
  // Without a transcript to jump in (a gallery, another surface), the marks are plain text.
  const bare = renderToStaticMarkup(<Markdown claims={[backed]}>{"All tests pass."}</Markdown>);
  expect(bare).not.toContain("<a ");
  expect(bare).toContain("cv-claim--backed");
});

test("a claim inside a link's label draws no mark: a link holds no link", () => {
  const html = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <Markdown claims={[backed]}>{"See [All tests pass](https://example.com/ci)."}</Markdown>
    </TurnActionsContext.Provider>,
  );
  expect(html).not.toContain("cv-claim");
});

test("a claim inside code or one the reply does not hold draws no mark", () => {
  const html = renderToStaticMarkup(<Markdown claims={[backed]}>{"Ran `All tests pass` as a string."}</Markdown>);
  expect(html).not.toContain("cv-claim");
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { kind: string; text?: string; claims?: ClaimCheck[] };

test("a turn's claim_checks mark its last reply, also on a page built from history", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const reply = (text: string) => ({
    update: { sessionUpdate: "agent_message_chunk", messageId: "m1", content: { type: "text", text } },
  });
  const steps = [
    { mux: "user_message", msg: { text: "Fix it" } },
    { mux: "turn_started", msg: { turnId: "t" } },
    {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        kind: "execute",
        title: "cargo test",
        rawInput: { command: "cargo test" },
        status: "in_progress",
      },
    },
    {
      update: { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed", rawOutput: { exit_code: 0 } },
    },
    reply("Fixed. All tests pass"),
    reply(" and lint is clean."),
    {
      mux: "claim_checks",
      msg: {
        turnId: "t",
        claims: [
          { text: "All tests pass", kind: "tests", verdict: "backed", toolCallId: "t1", command: "cargo test" },
          { text: "lint is clean", kind: "lint", verdict: "none" },
          { text: "the build succeeds", kind: "build", verdict: "none" },
        ],
      },
    },
    { mux: "turn_end", msg: { turnId: "t", stopReason: "end_turn" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const marked = () => rows.find((row) => row.kind === "assistant" && row.claims);
    while (!marked()) await new Promise<void>((resolve) => wakes.push(resolve));
    expect(marked()!.text).toBe("Fixed. All tests pass and lint is clean.");
    // The phrase the reply does not hold ("the build succeeds") is dropped, not guessed at.
    expect(marked()!.claims!.map((claim) => [claim.text, claim.verdict])).toEqual([
      ["All tests pass", "backed"],
      ["lint is clean", "none"],
    ]);
  } finally {
    client.close?.();
  }
});
