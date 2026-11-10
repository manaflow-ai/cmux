// A finished subagent's card shows its whole report as Markdown, or its whole blocks with a Show
// more that opens the rest in place; never a cut span (Leo, 2026-11-09, on a "Subagent finished"
// card that stopped at `**24 clean, f…`: "whoa this isn't rendering the full message nor having a
// show more as it shuold"). acpmux caps a Claude subagent's `lastMessage` at 240 characters
// (subagents.rs `truncate_last_message`), and that cut went through a bold span.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { SubagentNavContext, SubagentViewsContext } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import { SubagentReplyContext } from "../src/agent-session/acpmux/subagents/wholeReport";
import { DoneReportLookContext } from "../src/agent-session/acpmux/subagents/subagentDoneLineModel";
import { TurnActionsContext } from "../src/agent-session/acpmux/conversation/turnActions";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import {
  isCappedPreview,
  shownOfCut,
  wholeBlocksAfter,
  wholeBlocksBefore,
} from "../src/agent-session/acpmux/conversation/markdownCut";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { settleReact } from "./support/domTeardown";

// The report from Leo's screenshot, long enough that acpmux's 240-character cut lands in the
// bold span of the first list item.
const REPORT = [
  "I freed about 7 GiB on build-box. Free space is now **39 GiB**, still about 1 GiB under the 40 GiB floor. It read 22 GiB when you briefed me, but 32 GiB when I started deleting; I didn't cause that 10 GiB drop.",
  "",
  "**Deleted:**",
  "",
  "- **24 clean, finished worktrees** under ~/Projects/checkouts, each merged or closed.",
  "- **3 stale build dirs** from lanes that ended last week.",
  "",
  "Nothing else was touched.",
].join("\n");

/// What acpmux sends as `lastMessage` (subagents.rs `truncate_last_message`): 239 characters and "…".
const capped = (text: string) => {
  const chars = Array.from(text);
  return chars.length > 240 ? `${chars.slice(0, 239).join("")}…` : text;
};

test("acpmux's cut of the report lands inside the bold span", () => {
  const preview = capped(REPORT);
  expect(preview.endsWith("…")).toBe(true);
  const lastLine = preview.split("\n").at(-1)!;
  expect(lastLine.startsWith("- **24 clean")).toBe(true);
  expect(lastLine.split("**").length % 2).toBe(0); // an odd count of `**`: the span is open
  expect(isCappedPreview(preview, 240)).toBe(true);
  expect(isCappedPreview("Done…", 240)).toBe(false);
  expect(isCappedPreview(REPORT, 240)).toBe(false);
});

test("a cut keeps whole blocks and never a cut span", () => {
  const shown = shownOfCut(capped(REPORT));
  expect(shown).toBe(REPORT.split("\n").slice(0, 3).join("\n"));
  expect(shown).not.toContain("24 clean");
  // A list keeps its whole items before the one the cut went through.
  expect(wholeBlocksBefore("Intro\n\n- one **a**\n- two **b**\n- thr…")).toBe("Intro\n\n- one **a**\n- two **b**");
  // A fence the cut left open is dropped whole, blank lines in it included.
  expect(wholeBlocksBefore("Intro\n\n```ts\nconst a = 1;\n\nconst b…")).toBe("Intro");
  // A cut through the first block leaves its plain words, no marks.
  expect(shownOfCut("Freed **39 Gi…")).toBe("Freed 39 Gi…");
  // A tail kept from a long reply starts at its first whole block.
  expect(wholeBlocksAfter("…ted. **Bold\nmore**\n\nWhole one.\n\nWhole two.")).toBe("Whole one.\n\nWhole two.");
  expect(wholeBlocksAfter("…de();\n```\n\nAfter the code.")).toBe("After the code.");
  // The closing fence ends the cut block: the paragraph right after it is whole.
  expect(wholeBlocksAfter("…de();\n```\nThe final result is **PASS**.\n\nMore details.")).toBe(
    "The final result is **PASS**.\n\nMore details.",
  );
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "IS_REACT_ACT_ENVIRONMENT",
];

const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "air",
  parent: null,
  name: "air",
  task: "Clean old repos on build-box",
  state: "completed",
  startedAt: 0,
  endedAt: 4_934_000,
  ...fields,
});

function render(
  one: Subagent,
  views: Record<string, AcpmuxRow[]> = {},
  readReply?: (id: string) => Promise<string | undefined>,
  opened: string[] = [],
  arm?: "preview",
): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  const row: AcpmuxRow = { id: "done-0", version: 1, at: 4_934_000, kind: SUBAGENT_DONE, subagents: [one] };
  act(() => {
    root = createRoot(host);
    root.render(
      <SubagentNavContext.Provider value={(id) => void opened.push(id ?? "")}>
        <SubagentViewsContext.Provider value={(id) => views[id]}>
          <SubagentReplyContext.Provider value={readReply}>
            <TurnActionsContext.Provider value={{ retryAgent: async () => undefined }}>
              <DoneReportLookContext.Provider value={arm}>
                <SubagentDoneLine row={row} />
              </DoneReportLookContext.Provider>
            </TurnActionsContext.Provider>
          </SubagentReplyContext.Provider>
        </SubagentViewsContext.Provider>
      </SubagentNavContext.Provider>,
    );
  });
  return host;
}

const click = async (element: Element) =>
  act(async () => {
    element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const open = async (host: HTMLElement) =>
  click(host.querySelector(".cv-subagent-report-row button.cv-agentmsg__toggle")!);
const report = (host: HTMLElement) => host.querySelector(".cv-subagent-done__report")!;
const moreRow = (host: HTMLElement) => host.querySelector<HTMLButtonElement>(".cv-subagent-done__more-row");

/// No `**` or other mark drawn as text: every bold is a <strong>.
const noRawMarks = (element: Element) => expect(element.textContent).not.toContain("**");

test("the card reads the whole report from the subagent's own transcript", async () => {
  const view: AcpmuxRow[] = [{ id: "r", version: 1, at: 1, kind: "assistant", text: REPORT }];
  const host = render(agent({ lastMessage: capped(REPORT) }), { air: view });
  await open(host);
  expect(report(host).textContent).toContain("Nothing else was touched.");
  expect([...report(host).querySelectorAll("strong")].map((b) => b.textContent)).toContain(
    "24 clean, finished worktrees",
  );
  noRawMarks(report(host));
  expect(moreRow(host)).toBeNull();
});

test("with only the capped preview, the card shows whole blocks and Show more opens the rest in place", async () => {
  const asked: string[] = [];
  const host = render(agent({ lastMessage: capped(REPORT) }), {}, async (id) => {
    asked.push(id);
    return REPORT;
  });
  await open(host);
  // Whole blocks only: the cut bold item is gone, and nothing reads as raw Markdown.
  expect(report(host).textContent).toContain("Deleted:");
  expect(report(host).textContent).not.toContain("24 clean");
  noRawMarks(report(host));
  // Nothing is read until Show more asks.
  expect(asked).toEqual([]);
  const more = moreRow(host);
  expect(more?.textContent).toBe("Show more");
  const card = report(host);
  await click(more!);
  expect(asked).toEqual(["air"]);
  // The rest opens in the same card, in place, and Show more is gone.
  expect(report(host)).toBe(card);
  expect(report(host).textContent).toContain("Nothing else was touched.");
  expect([...report(host).querySelectorAll("strong")].map((b) => b.textContent)).toContain(
    "24 clean, finished worktrees",
  );
  noRawMarks(report(host));
  expect(moreRow(host)).toBeNull();
});

test("when the rest cannot be read, Show more opens the subagent's view", async () => {
  const opened: string[] = [];
  const host = render(agent({ lastMessage: capped(REPORT) }), {}, async () => undefined, opened);
  await open(host);
  await click(moreRow(host)!);
  expect(opened).toEqual([]);
  // The read found nothing: the row stays, and now opens the view.
  await click(moreRow(host)!);
  expect(opened).toEqual(["air"]);
  noRawMarks(report(host));
});

test("a short last message is whole and gets no Show more", async () => {
  const host = render(agent({ lastMessage: "Done: **three** keys fixed." }));
  await open(host);
  expect(report(host).querySelector("strong")?.textContent).toBe("three");
  expect(moreRow(host)).toBeNull();
});

test("in the preview arm, Show more of a report only the view holds opens the view", async () => {
  const opened: string[] = [];
  const host = render(agent({ result: `…tail of it.\n\n${REPORT}` }), {}, undefined, opened, "preview");
  noRawMarks(report(host));
  await click(host.querySelector(".cv-subagent-done__more")!);
  expect(opened).toEqual(["air"]);
});

test("a reply's chunks after its end outrank the result acpmux snapshotted at the end", async () => {
  // Completion can come before the reply's last chunks (subagentFold.test.ts, "late chunks ...").
  const view: AcpmuxRow[] = [{ id: "r", version: 1, at: 1, kind: "assistant", text: "Opened **/pull/41**" }];
  const host = render(agent({ result: "Opened **/pull/4" }), { air: view });
  await open(host);
  expect(report(host).querySelector("strong")?.textContent).toBe("/pull/41");
  noRawMarks(report(host));
  expect(moreRow(host)).toBeNull();
});

test("a 4-backtick block holding a 3-backtick literal is whole, not a cut in code", () => {
  const tail = "…intro.\n\n````md\n```\nliteral\n```\n````\n\nAfter.";
  expect(wholeBlocksAfter(tail)).toBe("````md\n```\nliteral\n```\n````\n\nAfter.");
});

test("a loaded reply that starts mid-message is not whole: the card keeps Show more", async () => {
  const view: AcpmuxRow[] = [{ id: "r", version: 1, at: 1, kind: "assistant", text: "finished worktrees** removed." }];
  const host = render(agent({ lastMessage: capped(REPORT) }), { air: view }, async () => REPORT);
  await open(host);
  expect(report(host).textContent).not.toContain("removed.");
  expect(moreRow(host)).not.toBeNull();
  noRawMarks(report(host));
});
