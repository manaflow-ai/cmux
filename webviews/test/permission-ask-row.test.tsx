// A pending command asks in one quiet row (Leo 2026-10-14, "trash"). The chat showed the call as
// "Ran B=1 bun run lint --help", then a card that repeated the command as its bold title, under a
// lone unlock glyph, "1 request from this turn", "ACP requests only · Isolation unverified" and an
// "Expand details (⌥⌘4)" button. Codex and Claude ask in one row: the tool's glyph, a verb and the
// command once, the answers at its end while it waits, the rest a click away in plain words.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { PermissionClientState, PermissionGroup } from "../src/agent-session/acpmux/permissions/protocol";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IntersectionObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(_callback: () => void) {}
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) if (!saved.some(([savedKey]) => savedKey === key)) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");

// What a reader sees: no closed details' contents, nothing hidden.
function visibleText(node: Node): string {
  if (node.nodeType === dom.window.Node.TEXT_NODE) return node.textContent ?? "";
  if (!(node instanceof dom.window.Element)) return "";
  if (node.hasAttribute("hidden") || node.getAttribute("aria-hidden") === "true") return "";
  const parent = node.parentElement;
  if (parent?.tagName === "DETAILS" && !(parent as HTMLDetailsElement).open && node.tagName !== "SUMMARY") return "";
  return [...node.childNodes].map(visibleText).join(" ");
}
const count = (text: string, part: string) => text.split(part).length - 1;

const command = "B=1 bun run lint --help";
const callId = "call-lint";
const group = (state: PermissionGroup["state"]): PermissionGroup => ({
  groupId: "group-1",
  sessionId: "session-1",
  turnId: "turn-1",
  revision: 1,
  state,
  decisions: ["allow_once", "allow_chat", "deny"],
  decision: state === "resolved" ? "allow_once" : null,
  items: [
    {
      permissionId: "permission-1",
      state: state === "resolved" ? "resolved" : "pending",
      // Claude names a Bash call by its command.
      request: {
        toolCall: {
          toolCallId: callId,
          title: command,
          kind: "execute",
          rawInput: { command, cwd: "/Users/you/src/cmux" },
        },
      },
    },
  ],
});
const permissions = (state: PermissionGroup["state"]): PermissionClientState => ({
  supported: true,
  ready: true,
  groups: [group(state)],
  chatAllowance: false,
  loading: false,
  busy: false,
});
// The call as the transcript gets it while it waits for the answer.
const rows: AcpmuxRow[] = [
  { id: "user-1", version: 1, at: 1, kind: "user", text: "lint it" },
  {
    id: "activity-1",
    version: 1,
    at: 2,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: command,
        tool: { id: callId, title: command, kind: "execute", status: "pending", command },
      },
    ],
  },
];

test("a pending command asks in one row: its verb and command once, then Allow, Always, Deny", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  const { groupAskedCalls, withoutAskedCalls } = await import("../src/agent-session/acpmux/permissions/askRows");
  const state = permissions("pending");
  const asked = groupAskedCalls(state);
  const root = createRoot(dom.window.document.getElementById("root")!);
  const responses: string[] = [];
  await act(async () =>
    root.render(
      <>
        <VirtualTranscript
          rows={withoutAskedCalls(rows, asked)}
          sessionId="session-1"
          onToggleActivity={() => {}}
          expanded={new Set<string>()}
        />
        <PermissionPanel
          state={state}
          working
          onRespond={(_group, _revision, decision) => responses.push(decision)}
          onRetry={() => {}}
          onRevoke={() => {}}
          onRefresh={() => {}}
        />
      </>,
    ),
  );
  const document = dom.window.document;
  const panel = document.querySelector<HTMLElement>(".acpmux-permission-panel")!;
  const seen = visibleText(document.getElementById("root")!).replace(/\s+/g, " ");
  // The command once in the whole pane, with its verb; no internal words, no counts.
  expect(count(seen, command)).toBe(1);
  expect(visibleText(panel)).toContain("Run");
  for (const jargon of ["ACP", "Isolation", "from this turn", "Expand details", "Tool permissions"])
    expect(seen).not.toContain(jargon);
  // What Always grants stays in view while it can be chosen (cg-design-judge: hidden, 0-16).
  expect(seen).toContain("Always also allows this chat's later requests");
  // No tooltips: every control names itself.
  expect([...panel.querySelectorAll("[title]")].map((node) => node.outerHTML)).toEqual([]);
  // The answers, short, while it waits.
  const answers = () =>
    [...panel.querySelectorAll<HTMLButtonElement>("button")]
      .filter((button) => !button.hasAttribute("aria-expanded"))
      .map((button) => button.textContent?.trim());
  expect(answers()).toEqual(["Allow", "Always", "Deny"]);

  // The row opens by a click: the full command and the scope, in plain words.
  const toggle = panel.querySelector<HTMLButtonElement>("button[aria-expanded]")!;
  expect(toggle.textContent).toContain(command);
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  await act(async () => toggle.click());
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  const details = document.getElementById(toggle.getAttribute("aria-controls")!)!;
  expect(details.textContent).toContain(`$ ${command}`);
  expect(details.textContent).toContain("/Users/you/src/cmux");
  expect(details.textContent).not.toMatch(/ACP|Isolation/);

  const always = [...panel.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent?.trim() === "Always",
  )!;
  await act(async () => always.click());
  expect(responses).toEqual(["allow_chat"]);

  // Answered: the row stays in the transcript, the panel offers nothing to press.
  await act(async () =>
    root.render(
      <PermissionPanel
        state={permissions("resolved")}
        working
        onRespond={() => {}}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  const answered = document.querySelector<HTMLElement>(".acpmux-permission-panel");
  expect([...(answered?.querySelectorAll("button") ?? [])].map((button) => button.textContent?.trim())).not.toContain(
    "Allow",
  );
  await act(async () => root.unmount());
});

test("a grouped ACP subject command keeps its command and scope visible", async () => {
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  const state = permissions("pending");
  state.groups[0]!.items[0]!.request = {
    title: "Run the check",
    subject: { type: "command", command: "bun test", cwd: "/workspace/project" },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(
      <PermissionPanel
        state={state}
        working
        onRespond={() => {}}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  const panel = document.querySelector<HTMLElement>(".acpmux-permission-panel")!;
  expect(visibleText(panel)).toContain("bun test");
  expect(visibleText(panel)).toContain("In /workspace/project");
  await act(async () => root.unmount());
});

test("a minimal ACP tool subject uses the request title in the grouped row", async () => {
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  const state = permissions("pending");
  state.groups[0]!.items[0]!.request = {
    title: "Allow Calculator control",
    subject: { type: "tool_call", toolCall: { toolCallId: callId } },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(
      <PermissionPanel
        state={state}
        working
        onRespond={() => {}}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  expect(visibleText(document.querySelector<HTMLElement>(".acpmux-permission-panel")!)).toContain(
    "Allow Calculator control",
  );
  await act(async () => root.unmount());
});

// Leo, 2026-10-21 ("this literally doesn't work"): a chat on another machine drew Allow, Always and
// Deny, and every answer came back refused. That machine's acpmux allows only from its own app, and
// the read says so (`allowRefused`): the row offers Deny, which counts, and says where to approve.
test("an ask whose allows the daemon refuses offers only Deny and says where to approve", async () => {
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const responses: string[] = [];
  const state = { ...permissions("pending"), allowRefused: "permission.person_required" };
  await act(async () =>
    root.render(
      <PermissionPanel
        state={state}
        working
        onRespond={(_group, _revision, decision) => responses.push(decision)}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  const panel = dom.window.document.querySelector<HTMLElement>(".acpmux-permission-panel")!;
  const buttons = [...panel.querySelectorAll<HTMLButtonElement>("button")].filter(
    (button) => !button.hasAttribute("aria-expanded"),
  );
  expect(buttons.map((button) => button.textContent?.trim())).toEqual(["Deny"]);
  const seen = visibleText(panel).replace(/\s+/g, " ");
  expect(seen).toContain("Only the cmux app can approve this. Approve it in cmux on the Mac that runs this chat.");
  expect(seen).not.toContain("Always also allows");
  // The allow shortcuts do nothing; Deny's still answers.
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.Event("cmux-acpmux-permissionAllowOnce"));
    dom.window.dispatchEvent(new dom.window.Event("cmux-acpmux-permissionAllowChat"));
  });
  expect(responses).toEqual([]);
  await act(async () => buttons[0]!.click());
  expect(responses).toEqual(["deny"]);
  await act(async () => root.unmount());
});
