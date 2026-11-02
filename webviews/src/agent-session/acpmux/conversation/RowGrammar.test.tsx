// l10n-allow-file: test fixtures.
// The transcript's one row grammar (design/chat-transcript.md "One row grammar"; Leo 2026-10-29:
// "this ui isn't consistent :(" and "this rendering can be better for sent stuff"). Four row kinds
// drawn side by side, a SendMessage call, a shell `acpmux send`, "Ran 2 commands" and "Subagent
// finished", share one layout: the tool rows' grid (`.cv-tool`), the icon first, the sentence,
// then the trailing column (status, then duration), then the chevron last. A send reads "Sent to"
// with its recipient as the one chip, and a shut send's first line shows once.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SubagentHarnessContext } from "../subagents/SubagentGroup";
import { SubagentDoneLine } from "../subagents/SubagentDoneLine";
import { acpmuxSendCall } from "./acpmuxSends";
import { agentMessage } from "./agentMessages";
import { MessageCard } from "./MessageCard";
import { AcpmuxSendLine } from "./SentMessageLine";
import { ToolGroupRow } from "./ToolGroupRow";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const sendMessage: Tool = {
  id: "toolu_send",
  title: "SendMessage",
  kind: "other",
  status: "completed",
  inputSummary: JSON.stringify({ to: "Organize the sidebar", message: "The sessions you set up should nest." }),
  output: JSON.stringify({ queued: true }),
};
const shellSend: Tool = {
  id: "toolu_shell",
  title: "acpmux send",
  kind: "execute",
  status: "completed",
  command: "acpmux send --no-wait fanout-infra 'From the coordinator, an addition to the broker blocker.'",
  output: "queued",
};
const commands: AcpmuxActivity[] = ["git status", "git log -1"].map((command, at) => ({
  kind: "tool",
  text: command,
  tool: { id: `cmd-${at}`, title: command, kind: "execute", status: "completed", command },
}));
const subagentRow: AcpmuxRow = {
  id: "done",
  version: 1,
  at: 148_000,
  kind: "activity",
  settled: true,
  subagents: [
    { id: "sa-1", parent: null, name: "Audit agent friction", state: "completed", startedAt: 0, endedAt: 148_000 },
  ],
} as AcpmuxRow;

async function fourRows(): Promise<{ container: HTMLElement; rows: Record<string, HTMLElement> }> {
  const message = agentMessage(sendMessage)!;
  const container = await render(
    <>
      <div data-kind="send-message">
        <MessageCard item={{ kind: "tool", text: sendMessage.title, tool: sendMessage }} message={message} />
      </div>
      <div data-kind="acpmux-send">
        <AcpmuxSendLine tool={shellSend} send={acpmuxSendCall(shellSend)!} />
      </div>
      <div data-kind="commands">
        <ToolGroupRow kind="commands" items={commands} disclosureKey="group" folded />
      </div>
      <div data-kind="subagent">
        <SubagentDoneLine row={subagentRow} />
      </div>
    </>,
  );
  const rows: Record<string, HTMLElement> = {};
  for (const kind of ["send-message", "acpmux-send", "commands", "subagent"]) {
    const row = container.querySelector<HTMLElement>(`[data-kind="${kind}"] .cv-tool:not(.cv-tool .cv-tool)`);
    if (!row) throw new Error(`no row for ${kind}`);
    rows[kind] = row;
  }
  return { container, rows };
}

/// The row's own columns, in order: its direct children that draw (React's text spaces aside).
/// A row whose open button holds the icon and sentence (the subagent line, so Restart and Retry
/// can sit beside it rather than inside a button) counts that button's children in its place.
const columns = (row: Element): string[] =>
  [...row.children].flatMap((child) =>
    child.firstElementChild?.classList.contains("cv-tool__icon")
      ? columns(child)
      : [
          child.classList.contains("cv-tool__icon")
            ? "icon"
            : child.classList.contains("cv-tool__trail")
              ? "trail"
              : child.classList.contains("cv-tool__chevron")
                ? "chevron"
                : "sentence",
        ],
  );

test("the four row kinds share one row grammar: icon, sentence, trailing column, chevron last", async () => {
  const { rows } = await fourRows();
  for (const [kind, row] of Object.entries(rows)) {
    const order = columns(row);
    expect({ kind, first: order[0] }).toEqual({ kind, first: "icon" });
    expect({ kind, last: order.at(-1) }).toEqual({ kind, last: "chevron" });
    // The trailing column, when a row has one, sits right before the chevron.
    const trail = order.indexOf("trail");
    if (trail !== -1) expect({ kind, trail }).toEqual({ kind, trail: order.length - 2 });
    // Every chevron is the same glyph in the same slot.
    expect(row.lastElementChild!.matches(".cv-tool__chevron, svg.cv-tool__chevron")).toBe(true);
  }
});

/// The rows' stylesheets, as the pane loads them, so a computed `order` reads what draws.
const ROW_SHEETS = [
  "./conversation.css",
  "./AgentMessageRow.css",
  "./SubsessionCallCard.css",
  "./TranscriptActivityRow.css",
  "../subagents/subagents.css",
];

/// The row's direct children as flexbox draws them: by CSS `order`, then DOM order.
const drawn = (row: Element): string[] => {
  const view = row.ownerDocument.defaultView!;
  return [...row.children]
    .map((child, at) => ({ child, at, order: Number(view.getComputedStyle(child).order || 0) }))
    .sort((a, b) => a.order - b.order || a.at - b.at)
    .map(({ child }) =>
      child.classList.contains("cv-tool__trail")
        ? "trail"
        : child.classList.contains("cv-tool__chevron")
          ? "chevron"
          : "other",
    );
};

test("each row draws its trailing status or duration before the chevron, and the chevron last", async () => {
  const { container, rows } = await fourRows();
  const doc = container.ownerDocument;
  for (const sheet of ROW_SHEETS) {
    const style = doc.createElement("style");
    style.textContent = readFileSync(new URL(sheet, import.meta.url), "utf8");
    doc.head.append(style);
  }
  for (const [kind, row] of Object.entries(rows)) {
    const order = drawn(row);
    // The chevron is drawn last on every row, so it sits on one x at the row's end.
    expect({ kind, last: order.at(-1) }).toEqual({ kind, last: "chevron" });
    // The trailing column, when a row has one, is drawn right before it, never after.
    const trail = order.indexOf("trail");
    if (trail !== -1) expect({ kind, trail }).toEqual({ kind, trail: order.length - 2 });
  }
  // The sends and the subagent line carry a trailing column, so the check above bites on them.
  for (const kind of ["send-message", "acpmux-send", "subagent"])
    expect({ kind, trail: drawn(rows[kind]!).includes("trail") }).toEqual({ kind, trail: true });
});

test("a send reads Sent to <recipient>, the recipient one chip, its status in the trailing column", async () => {
  const { rows } = await fourRows();
  for (const kind of ["send-message", "acpmux-send"]) {
    const row = rows[kind]!;
    const words = row.querySelector(".cv-agentmsg__words")!.textContent;
    expect({ kind, words }).toEqual({ kind, words: "Sent to" });
    const chips = row.querySelectorAll(".cv-recipient");
    expect({ kind, chips: chips.length }).toEqual({ kind, chips: 1 });
    expect(chips[0]!.classList.contains("cv-agentmsg__name")).toBe(true);
    // The status is the trailing column's word, never part of the sentence.
    // The shell send's word is the CLI's own lowercase "queued"; .cv-row-status capitalises its
    // first letter in CSS, so both rows draw "Queued".
    const trail = row.querySelector(".cv-tool__trail");
    const status = trail?.textContent?.toLowerCase();
    expect({ kind, status }).toEqual({ kind, status: "queued" });
    if (kind === "acpmux-send") expect(trail!.querySelector(".cv-row-status")).not.toBeNull();
    expect(row.querySelector(".cv-agentmsg__sentence")!.textContent).not.toContain("queued");
  }
  expect(rows["send-message"]!.querySelector(".cv-recipient")!.textContent).toBe("Organize the sidebar");
  expect(rows["acpmux-send"]!.querySelector(".cv-recipient")!.textContent).toBe("fanout-infra");
});

test("every message preview is cut by the one rule: one muted span that ellipsizes", async () => {
  const { rows } = await fourRows();
  for (const kind of ["send-message", "acpmux-send"]) {
    const previews = rows[kind]!.querySelectorAll(".cv-agentmsg__preview");
    expect({ kind, previews: previews.length }).toEqual({ kind, previews: 1 });
  }
  const css = readFileSync(new URL("./AgentMessageRow.css", import.meta.url), "utf8");
  const rule = /\.cv-agentmsg__preview \{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(rule).toContain("text-overflow: ellipsis");
  expect(rule).toContain("white-space: nowrap");
});

test("the subagent line's duration is in the trailing column, not the sentence", async () => {
  const { rows } = await fourRows();
  const row = rows.subagent!;
  expect(row.querySelector(".cv-tool__text")!.textContent).toBe("Subagent finished: Audit agent friction");
  expect(row.querySelector(".cv-tool__trail")!.textContent).toBe("2m 28s");
  // Its name for a screen reader still reads the whole line.
  expect(row.querySelector("button.cv-subagent-done")!.getAttribute("aria-label")).toBe(
    "Subagent finished: Audit agent friction · 2m 28s",
  );
});

// Leo, 2026-10-28: "Shouldn't the subagent icon be different?" A subagent's line never draws the
// chat bubble every chat and session list carries.
test("a subagent's line with no harness known draws the subagent mark, not the chat bubble", async () => {
  const { rows } = await fourRows();
  const icon = rows.subagent!.querySelector(".cv-tool__icon")!;
  expect(icon.querySelector('[data-icon="agent.session"]')).toBeNull();
  expect(icon.querySelector('[data-icon="task.ai"]')).not.toBeNull();
});

test("a subagent's line draws the chat's harness mark when the subagent names none", async () => {
  const container = await render(
    <SubagentHarnessContext.Provider value="claude">
      <SubagentDoneLine row={subagentRow} />
    </SubagentHarnessContext.Provider>,
  );
  const icon = container.querySelector(".cv-tool__icon")!;
  expect(icon.querySelector('[data-icon="agent.session"]')).toBeNull();
  expect(icon.querySelector('[data-icon="task.ai"]')).toBeNull();
  expect(icon.children.length).toBeGreaterThan(0);
});

test("an opened send shows its message once, under the row, not again on the line", async () => {
  const { rows } = await fourRows();
  for (const kind of ["send-message", "acpmux-send"]) {
    const row = rows[kind]!;
    const toggle = row.querySelector<HTMLElement>(".cv-agentmsg__toggle") ?? row;
    await act(async () => toggle.click());
    expect({ kind, preview: row.querySelector(".cv-agentmsg__preview")?.textContent ?? "" }).toEqual({
      kind,
      preview: "",
    });
  }
});

test("the trailing column and chevron use the shared flex row contract", () => {
  const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
  const block = (selector: string) =>
    new RegExp(`(?:^|\\n)${selector.replace(/[.]/g, "\\.")} \\{([^}]*)\\}`).exec(css)?.[1] ?? "";
  expect(block(".cv-tool")).toContain("display: flex");
  expect(block(".cv-tool__chevron")).toContain("order: 3");
  expect(css).toContain(".cv-tool:not(.cv-agentmsg__line) > .cv-command__meta,");
  expect(css).toContain("  order: 4;");
  // Message rows use the same shared flex sentence, with the trailing status outside it.
  const agentCss = readFileSync(new URL("./AgentMessageRow.css", import.meta.url), "utf8");
  const sentence = /\.cv-agentmsg__sentence \{([^}]*)\}/.exec(agentCss)?.[1] ?? "";
  expect(sentence).toContain("flex: 1 1 0");
  expect(sentence).toContain("overflow: hidden");
});

test("the subagent row's one button reaches its trailing markers", () => {
  const css = readFileSync(new URL("../subagents/subagents.css", import.meta.url), "utf8");
  const row = /\.cv-tool\.cv-subagent-done-row \{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(row).toContain("position: relative");
  expect(row).toContain("isolation: isolate");
  const hitArea = /\.cv-subagent-done::before \{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(hitArea).toContain('content: ""');
  expect(hitArea).toContain("inset: 0");
  expect(hitArea).toContain("z-index: var(--layer-backdrop)");
});

test("a started sub-session's row names the session, with no narration in front of it", () => {
  const source = readFileSync(new URL("./SubsessionCallCard.tsx", import.meta.url), "utf8");
  expect(source).not.toContain('t("subsession.started"');
});
