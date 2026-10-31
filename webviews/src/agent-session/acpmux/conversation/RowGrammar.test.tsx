// l10n-allow-file: test fixtures.
// The transcript's one row grammar (design/chat-transcript.md "One row grammar"; Leo 2026-10-29:
// "this ui isn't consistent :(" and "this rendering can be better for sent stuff"). Four row kinds
// drawn side by side, a SendMessage call, a shell `acpmux send`, "Ran 2 commands" and "Subagent
// finished", share one layout: the tool rows' flex row (`.cv-tool`), the icon first, the sentence
// with its chevron right after it (base's inline carets, #28018), then the trailing column (status,
// or duration) at the row's right edge. A send reads "Sent to" with its recipient as the one chip,
// and a shut send's first line shows once.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SubagentDoneLine } from "../subagents/SubagentDoneLine";
import { SubagentNavContext } from "../subagents/SubagentGroup";
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
        {/* A line that opens its subagent, so it draws its chevron. */}
        <SubagentNavContext.Provider value={() => {}}>
          <SubagentDoneLine row={subagentRow} />
        </SubagentNavContext.Provider>
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

test("the four row kinds share one grammar: icon first, one chevron, no status in the sentence", async () => {
  const { rows } = await fourRows();
  for (const [kind, row] of Object.entries(rows)) {
    // The icon leads, whether the row holds it or its one open button does.
    const first = row.firstElementChild!;
    const icon = first.classList.contains("cv-tool__icon") ? first : first.firstElementChild;
    expect({ kind, icon: icon?.classList.contains("cv-tool__icon") }).toEqual({ kind, icon: true });
    // One chevron, inside the row's one control (never a control of its own).
    const chevrons = row.querySelectorAll(".cv-tool__chevron");
    expect({ kind, chevrons: chevrons.length }).toEqual({ kind, chevrons: 1 });
    // The trailing column, when a row has one, is the row's own child, after its sentence.
    const trail = row.querySelector(".cv-tool__trail");
    if (trail) expect({ kind, parent: trail.parentElement === row }).toEqual({ kind, parent: true });
  }
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
    const sentence = [...row.childNodes]
      .filter((node) => node !== trail)
      .map((node) => node.textContent)
      .join("");
    expect(sentence.toLowerCase()).not.toContain("queued");
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

test("the trailing column sits at the row's right edge, the chevron inline after the label", () => {
  const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
  const block = (selector: string) =>
    new RegExp(`(?:^|\\n)${selector.replace(/[.()>:]/g, "\\$&")} \\{([^}]*)\\}`).exec(css)?.[1] ?? "";
  // Base's inline carets (#28018): no pinned chevron column.
  expect(block(".cv-tool")).toContain("display: flex");
  expect(block(".cv-tool__chevron")).not.toContain("grid-column");
  expect(block(".cv-tool__trail")).toContain("margin-inline-start: auto");
  expect(block(".cv-tool:not(.cv-agentmsg__line) > .cv-tool__trail")).toContain("order: 4");
  // The message line keeps base's flex sentence, its chevron inside the toggle.
  const agentCss = readFileSync(new URL("./AgentMessageRow.css", import.meta.url), "utf8");
  const line = /\.cv-agentmsg__line \{([^}]*)\}/.exec(agentCss)?.[1] ?? "";
  expect(line).toContain("display: flex");
});

/// What a keyboard reaches in `row`: buttons, links and anything with a tab stop, enabled.
const focusable = (row: Element) =>
  [...row.querySelectorAll<HTMLElement>("button, a[href], [tabindex]")].filter(
    (element) => !(element as HTMLButtonElement).disabled && element.getAttribute("tabindex") !== "-1",
  );

test("a subagent done line is one control: its chevron only draws and opens nothing of its own", async () => {
  const opened: string[] = [];
  const container = await render(
    <SubagentNavContext.Provider value={(id) => void opened.push(id ?? "")}>
      <SubagentDoneLine row={subagentRow} />
    </SubagentNavContext.Provider>,
  );
  const row = container.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  // One focusable control, the open button, which names the whole line.
  const controls = focusable(row);
  expect(controls.map((element) => element.className)).toEqual(["cv-tool cv-bgtask cv-subagent-done"]);
  // The chevron only draws, inside that button: hidden from assistive tech, no tab stop, no
  // pointer role and no handler of its own.
  const chevron = row.querySelector<SVGElement>(".cv-tool__chevron")!;
  expect(chevron.getAttribute("aria-hidden")).toBe("true");
  expect(chevron.closest<HTMLElement>("button")).toBe(controls[0]!);
  expect(chevron.hasAttribute("tabindex")).toBe(false);
  expect(chevron.hasAttribute("data-interactive")).toBe(false);
  // The button is what opens it.
  await act(async () => controls[0]!.click());
  expect(opened).toEqual(["sa-1"]);
  // The button's hit area spans the row, and the duration lets a click through to it.
  const css = readFileSync(new URL("../subagents/subagents.css", import.meta.url), "utf8");
  expect(css).toMatch(/\.cv-subagent-done-row > \.cv-subagent-done::before \{[^}]*position: absolute;[^}]*inset: 0;/);
  expect(css).toMatch(/\.cv-subagent-done-row > \.cv-subagent-done__trail \{\s*pointer-events: none;/);
});

test("a message row's chevron only draws: the toggle is its one control for opening", async () => {
  const { rows } = await fourRows();
  const row = rows["send-message"]!;
  const chevron = row.querySelector<SVGElement>(".cv-tool__chevron")!;
  const toggle = row.querySelector<HTMLElement>(".cv-agentmsg__toggle")!;
  // Inside the toggle, never a control of its own: no handler, no tab stop, hidden from AT.
  expect(chevron.getAttribute("aria-hidden")).toBe("true");
  expect(chevron.hasAttribute("data-interactive")).toBe(false);
  expect(chevron.hasAttribute("tabindex")).toBe(false);
  expect(focusable(row).filter((element) => element.contains(chevron))).toEqual([toggle]);
  // The status only draws too; the toggle's hit area reaches it.
  expect(row.querySelector(".cv-tool__trail")!.querySelector("button, [data-interactive]")).toBeNull();
  await act(async () => toggle.click());
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  const css = readFileSync(new URL("./AgentMessageRow.css", import.meta.url), "utf8");
  expect(css).toMatch(/\.cv-agentmsg__toggle::before \{[^}]*position: absolute;[^}]*inset: 0;/);
  expect(css).toMatch(/\.cv-agentmsg__line > \.cv-tool__trail \{\s*pointer-events: none;/);
});

test("a started sub-session's row names the session, with no narration in front of it", () => {
  const source = readFileSync(new URL("./SubsessionCallCard.tsx", import.meta.url), "utf8");
  expect(source).not.toContain('t("subsession.started"');
});
