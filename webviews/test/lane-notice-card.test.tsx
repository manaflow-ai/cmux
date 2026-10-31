// l10n-allow-file: synthetic lane report fixtures and their visible copy.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;
const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { LaneNoticeBatch } = await import("../src/agent-session/acpmux/conversation/LaneNoticeBatch");
const { batchLaneNotices } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
const { PendingMessagesCard } = await import("../src/agent-session/acpmux/conversation/PendingMessagesCard");
const { pendingMessagesRow } = await import("../src/agent-session/acpmux/conversation/pendingMessages");
const { FindReveal, findRowIndex, findMemberRowId } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { PromptMarksSession } = await import("../src/agent-session/acpmux/threadMinimap/promptMarks");
const { TranscriptDisclosureProvider } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});
const SHA = "1234567890abcdef1234567890abcdef12345678";
const FINDING =
  "[P2] Preserve the sender session when the queued report is delivered so its name opens the correct chat after a reconnect instead of silently losing its target.";
function report(id: string, verdict = "SHIP"): AcpmuxRow {
  const text = `lane report: turn 1 ended, idle.\nSession: secret-session-${id}\nLast message: Review (Astra): ${verdict} at ${SHA}\n${verdict === "BLOCK" ? FINDING : "No findings."}\nCommits named: ${SHA}\n(acpmux sends this when a lane ends. Answer only if it needs you.)`;
  return {
    id,
    version: 1,
    at: 100,
    kind: "user",
    text,
    incoming: {
      kind: "message",
      message: { name: id, sessionId: `session-${id}`, report: true, text, raw: `[${id}] ${text}` },
    },
  };
}
let sessionNumber = 0;
async function mount(
  rows: AcpmuxRow[],
  target?: { rowId: string; matchRowId?: string; needle: string },
  waiting = false,
) {
  root = createRoot(host);
  const opened: string[] = [];
  let repaints = 0;
  const renderMessage = (row: AcpmuxRow) =>
    row.incoming?.kind === "message" ? (
      <IncomingMessageLine
        key={row.id}
        id={row.id}
        message={row.incoming.message}
        onOpen={(id) => void opened.push(id)}
      />
    ) : null;
  const pending = waiting
    ? pendingMessagesRow(
        rows.map((row) => ({ ...row, steer: "waiting" as const })),
        [],
      )
    : undefined;
  const grouped = pending ? [pending] : batchLaneNotices(rows);
  const renderNotice = (row: AcpmuxRow) =>
    row.laneNoticeBatch ? <LaneNoticeBatch key={row.id} row={row} renderMessage={renderMessage} /> : renderMessage(row);
  await act(async () =>
    root!.render(
      <PromptMarksSession.Provider value={`lane-notice-card-${++sessionNumber}`}>
        <TranscriptDisclosureProvider sessionId={`lane-notice-card-${sessionNumber}`}>
          <FindReveal.Provider
            value={target ? { ...target, card: false, repaint: () => void (repaints += 1) } : undefined}
          >
            {grouped.map((row) =>
              row.pendingMessages ? (
                <PendingMessagesCard
                  key={row.id}
                  row={row}
                  onOpen={(id) => void opened.push(id)}
                  renderMessage={renderNotice}
                />
              ) : (
                renderNotice(row)
              ),
            )}
          </FindReveal.Provider>
        </TranscriptDisclosureProvider>
      </PromptMarksSession.Provider>,
    ),
  );
  return { grouped, opened, repaints: () => repaints };
}
const click = async (selector: string) => {
  const button = host.querySelector<HTMLButtonElement>(selector);
  expect(button).not.toBeNull();
  await act(async () => button!.click());
};

test("five ended reports collapse to one count and preserve all five independent rows", async () => {
  const rows = Array.from({ length: 5 }, (_, i) => report(`review-${i}`, i === 4 ? "BLOCK" : "SHIP"));
  await mount(rows);
  const toggle = host.querySelector(".cv-lane-batch__toggle")!;
  expect(toggle.textContent).toBe("5 reviews ended · 4 SHIP, 1 BLOCK");
  expect(toggle.textContent).not.toContain("\n");
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector(".cv-received")).toBeNull();
  await click(".cv-lane-batch__toggle");
  expect(host.querySelectorAll(".cv-received")).toHaveLength(5);
  expect(host.querySelectorAll('.cv-received .cv-disclosure__toggle[aria-expanded="false"]')).toHaveLength(5);
  expect(host.querySelectorAll("[data-find-member]")).toHaveLength(5);
  await click(".cv-lane-batch__toggle");
  expect(host.querySelector(".cv-received")).toBeNull();
});

test("a single report shows its verdict; its full P2 remains readable and metadata is under Details", async () => {
  const { opened } = await mount([report("single-block", "BLOCK")]);
  expect(host.querySelector(".cv-lane-batch")).toBeNull();
  expect(host.querySelector(".cv-received__preview")?.textContent).toContain("BLOCK");
  expect(host.querySelector(".cv-received__preview")?.textContent).not.toContain("lane report: turn");
  expect(host.querySelector(".cv-received__preview")?.textContent).not.toContain("\n");
  expect(host.querySelector(".cv-received__text")).toBeNull();
  await click(".cv-received__from--open");
  expect(opened).toEqual(["session-single-block"]);
  expect(host.querySelector(".cv-received__text")).toBeNull();
  await click(".cv-disclosure__toggle");
  expect(host.querySelector(".cv-received__text")?.textContent).toContain(FINDING);
  expect(host.querySelector(".cv-received__text")?.textContent).not.toContain("Session:");
  expect(host.querySelector(".cv-received__text")?.textContent).not.toContain("Commits named:");
  expect(host.querySelector(".cv-received__text")?.textContent).not.toContain("acpmux sends this");
  expect(host.querySelector(".cv-received__details pre")).toBeNull();
  await click(".cv-received__more");
  expect(host.querySelector(".cv-received__details pre")?.textContent).toContain("secret-session-single-block");
  expect(host.querySelector(".cv-received__details pre")?.textContent).toContain(SHA);
  expect(host.querySelectorAll(".cv-received__details pre")).toHaveLength(1);
});

test("structured lane report details appear exactly once after opening Details", async () => {
  const details = { session: "structured-report-session", commits: [SHA] };
  const text = "SHIP at 1234567890ab · no findings · turn 1, idle";
  await mount([
    {
      id: "structured-details",
      version: 1,
      at: 100,
      kind: "user",
      text,
      incoming: { kind: "message", message: { name: "review", report: true, text, raw: text, details } },
    },
  ]);
  await click(".cv-disclosure__toggle");
  expect(host.querySelector(".cv-received__details pre")).toBeNull();
  await click(".cv-received__more");
  const serialized = JSON.stringify(details, null, 2);
  expect(host.querySelectorAll(".cv-received__details pre")).toHaveLength(1);
  expect(host.querySelector(".cv-received__details pre")?.textContent).toBe(serialized);
  expect(host.textContent!.split(serialized)).toHaveLength(2);
});

test("Find opens the batch and only the member holding its match", async () => {
  const rows = [report("find-good"), report("find-block", "BLOCK")];
  const grouped = batchLaneNotices(rows);
  const batch = grouped[findRowIndex(grouped, "find-block")]!;
  // Use the same mapping as VirtualTranscript: searching the raw member must preserve its
  // identity when the virtual row is the delivered batch.
  const matchRowId = findMemberRowId(batch, "find-block");
  expect(matchRowId).toBe("find-block");
  const drawn = await mount(rows, { rowId: batch.id, matchRowId, needle: "silently losing its target" });
  expect(host.querySelector(".cv-lane-batch__toggle")?.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector('[data-row-id="find-good"] .cv-disclosure__toggle')?.getAttribute("aria-expanded")).toBe(
    "false",
  );
  expect(host.querySelector('[data-row-id="find-block"] .cv-disclosure__toggle')?.getAttribute("aria-expanded")).toBe(
    "true",
  );
  expect(host.querySelector('[data-row-id="find-block"] .cv-received__text')?.textContent).toContain(FINDING);
  expect(drawn.repaints()).toBeGreaterThan(0);
});

test("three inbox notices share one line and expose each notice when opened", async () => {
  const senders = ["pane-tools", "layout-review", "message-rows"];
  const rows: AcpmuxRow[] = senders.map((sender, i) => {
    const text = `New messages from other agents in 1 thread.\n- 1 new in #${300 + i} from ${sender}: Ready for review. (thread from:${sender}/pr:${300 + i})`;
    return {
      id: `inbox-${i}`,
      version: 1,
      at: i,
      kind: "user",
      text,
      incoming: {
        kind: "message",
        message: {
          name: "inbox",
          text,
          raw: `[inbox] ${text}`,
          noticeThreads: [{ id: `from:${sender}/pr:${300 + i}`, sender }],
        },
      },
    };
  });
  await mount(rows);
  const toggle = host.querySelector(".cv-lane-batch__toggle")!;
  expect(toggle.textContent).toContain("3 inbox threads");
  for (const sender of senders) expect(toggle.textContent).toContain(sender);
  expect(toggle.textContent).not.toContain("\n");
  expect(host.querySelector(".cv-received")).toBeNull();
  await click(".cv-lane-batch__toggle");
  expect(host.querySelectorAll(".cv-received")).toHaveLength(3);
  await click('[data-row-id="inbox-1"] .cv-disclosure__toggle');
  expect(host.querySelector('[data-row-id="inbox-1"] .cv-received__text')?.textContent).toContain("Ready for review.");
});

test("waiting report batches keep every sender visible and clickable without a shared sender head", async () => {
  const { opened } = await mount([report("waiting-one"), report("waiting-two")], undefined, true);
  await click(".cv-pending__toggle");
  await click(".cv-lane-batch__toggle");
  const senders = [...host.querySelectorAll<HTMLElement>(".cv-received__from--open")];
  expect(senders).toHaveLength(2);
  // PendingMessagesCard.css hides sender chips below a shared sender head. A mixed report
  // batch has no such head and must stay outside that selector's scope.
  for (const sender of senders) expect(sender.closest(".cv-pending__sender")).toBeNull();
  await act(async () => senders[1]!.click());
  expect(opened).toEqual(["session-waiting-two"]);
});
