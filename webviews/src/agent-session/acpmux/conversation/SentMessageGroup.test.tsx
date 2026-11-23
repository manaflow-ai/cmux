// l10n-allow-file: test fixtures.
// A run of sent messages is one closed line (toolGroups.ts `sendGroup`, SentMessageLine.tsx
// `SentMessageGroup`). Leo, 2026-11-04, on a shell loop of `acpmux send` to 8 sessions drawn as 8
// rows, each ending "· and 1 more command", with a Copy on the right: "why arent these
// collapsed/collapsible/why is there even a copy button on the right here? let's do 1, let's remove
// copy button on 2".
//
// Before: one row per message, each saying the call ran "1 more command", and a hover Copy on
// each. After: "Sent 8 messages · and 1 more command" and the recipients, closed; opened, a row per
// message with no "more command" and no Copy.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { sendEntries, toolGroups } from "./toolGroups";
import { ToolRows } from "./TurnRows";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { turnView } from "./turns";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const LANES = ["ux-a", "ux-b", "ci-c", "ci-d", "cloud-e", "cloud-f", "perf-g", "perf-h"];
/// The call Leo's screenshot shows: one Bash loop of sends to 8 sessions, then one memory note.
const LOOP =
  `for s in ${LANES.join(" ")}; do acpmux send --no-wait "$s" "From claude-sr2-coord: the broker merges directly now."; done; ` +
  `agent-memory remember "broker merges directly"`;

const call = (command: string, fields: Partial<Tool> = {}): AcpmuxActivity => {
  const tool: Tool = {
    id: `toolu_${command.length}`,
    title: command.slice(0, 120),
    kind: "execute",
    status: "completed",
    command,
    exitCode: 0,
    ...fields,
  };
  return { kind: "tool", text: tool.title, tool };
};

const activity = (items: AcpmuxActivity[], fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "run",
  version: 1,
  at: 1000,
  kind: "activity",
  items,
  toolCount: items.length,
  ...fields,
});

test("a shell loop of 8 sends is one group of 8 messages, its other command counted once", () => {
  const groups = toolGroups([call(LOOP, { output: Array(8).fill("queued").join("\n") })]);
  expect(groups.map((group) => group.type)).toEqual(["sendGroup"]);
  const sends = sendEntries(groups);
  expect(sends.map((entry) => entry.send.target)).toEqual(LANES);
  expect(sends.every((entry) => entry.send.others === 1)).toBe(true);
});

test("adjacent calls that each sent one message group too; a lone send keeps its row", () => {
  const a = call("acpmux send --no-wait ux-a 'Rebase first.'", { id: "a" });
  const b = call("acpmux send --no-wait ux-b 'Then land it.'", { id: "b" });
  expect(toolGroups([a, b]).map((group) => group.type)).toEqual(["sendGroup"]);
  const read = {
    kind: "tool" as const,
    text: "Read",
    tool: { id: "r", title: "Read a", kind: "read", status: "completed" },
  };
  expect(toolGroups([a, read, b]).map((group) => group.type)).toEqual(["send", "item", "send"]);
});

test("a message card and a sub-session's send_message next to a shell send join its group", () => {
  const card: AcpmuxActivity = {
    kind: "tool",
    text: "SendMessage",
    tool: {
      id: "card",
      title: "SendMessage",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify({ to: "lane-x", message: "Rebase first." }),
    },
  };
  const subsession: AcpmuxActivity = {
    kind: "tool",
    text: "mcp__cmux-subsessions__send_message",
    tool: {
      id: "sub",
      title: "mcp__cmux-subsessions__send_message",
      status: "completed",
      inputSummary: JSON.stringify({ sessionId: "child-1", text: "Run the tests." }),
      output: JSON.stringify({ delivery: "queued" }),
    },
  };
  const shell = call("acpmux send --no-wait ux-a 'Then land it.'", { id: "shell" });
  const groups = toolGroups([card, shell, subsession]);
  expect(groups.map((group) => group.type)).toEqual(["sendGroup"]);
  if (groups[0]?.type === "sendGroup")
    expect(groups[0].entries.map((entry) => entry.type)).toEqual(["message", "send", "subsession"]);
});

test("the group draws closed as one line: Sent 8 messages, the other command once, the recipients, no Copy", async () => {
  const host = await render(<ToolRows row={activity([call(LOOP, { output: Array(8).fill("queued").join("\n") })])} />);
  const head = host.querySelector<HTMLElement>(".cv-sent-group .cv-message-group__head")!;
  expect(head).not.toBeNull();
  expect(head.getAttribute("aria-expanded")).toBe("false");
  expect(head.querySelector(".cv-message-group__count")?.textContent).toBe("Sent 8 messages · and 1 more command");
  expect(head.querySelector(".cv-message-group__senders")?.textContent).toBe(LANES.join(", "));
  // Closed, no message row draws.
  expect(host.querySelectorAll(".cv-sent-msg")).toHaveLength(0);
  expect(host.textContent?.match(/more command/g)).toHaveLength(1);

  await act(async () => head.click());
  expect(head.getAttribute("aria-expanded")).toBe("true");
  const rows = [...host.querySelectorAll<HTMLElement>(".cv-sent-group__body .cv-sent-msg")];
  expect(rows).toHaveLength(8);
  expect(rows.map((row) => row.querySelector(".cv-recipient")?.textContent)).toEqual(LANES);
  // The group's line said it: no message repeats "and 1 more command".
  for (const row of rows) expect(row.textContent).not.toContain("more command");
  expect(host.textContent?.match(/more command/g)).toHaveLength(1);
  // A message row has no Copy (Leo: "let's remove copy button").
  expect(host.querySelector('button[aria-label="Copy"]')).toBeNull();
  expect(host.querySelector(".cv-sent__actions, .cv-sent-actions")).toBeNull();
});

test("a lone send with other commands still names them on its own row, with no Copy", async () => {
  const host = await render(
    <ToolRows row={activity([call("git push -q && acpmux send --no-wait lane 'Pushed.'", { output: "queued" })])} />,
  );
  const row = host.querySelector<HTMLElement>(".cv-sent-msg")!;
  expect(row.textContent).toContain("and 1 more command");
  expect(host.querySelector(".cv-sent-group")).toBeNull();
  expect(host.querySelector('button[aria-label="Copy"]')).toBeNull();
});

test("a finished Claude turn of the loop draws the group's line, not 8 rows", () => {
  const rows: AcpmuxRow[] = [
    { id: "prompt", version: 1, at: 1, kind: "user", text: "Tell the lanes" },
    activity([call(LOOP, { output: Array(8).fill("queued").join("\n") })], { at: 2 }),
    { id: "answer", version: 1, at: 3, kind: "assistant", text: "Told all eight." },
    { id: "summary", version: 1, at: 4, kind: "turnSummary", status: "completed" },
  ];
  // Claude's in-place arm (claudeTurnFold.experiment.ts; the default folds the turn under "Worked
  // for"): its run draws in place, and that run is the one line.
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
  const view = turnView(rows, new Set(), { agentFamily: "claude" });
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
  expect(view.some((row) => row.kind === "worked")).toBe(false);
  const run = view.find((row) => row.id === "run")!;
  expect(run).toBeDefined();
  const groups = toolGroups(run.items ?? []);
  expect(groups.map((group) => group.type)).toEqual(["sendGroup"]);
  // One line already: no message-run line folds it a second time.
  expect(view.some((row) => row.kind === "messageRun")).toBe(false);
});
