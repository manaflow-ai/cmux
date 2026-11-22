// l10n-allow-file: test fixture tool titles and option names, not shipped UI.
// Codex review of #34386 (F1): a grouped ask drawn on its single card while its group read is out
// moves to the group's panel when the read lands. Someone writing a deny's instructions on the card
// lost them: the card unmounted, and the panel takes no instructions. Now the card says when its
// field opens and closes (onDraft), and the pane keeps the ask on its card while it is still pending
// (permissionKeys.ts heldOnCard).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import type { PermissionClientState } from "../src/agent-session/acpmux/permissions/protocol";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
const { heldOnCard } = await import("../src/agent-session/acpmux/permissionKeys");

const ask: AcpmuxPermission = {
  permissionId: "p1",
  groupId: "g1",
  title: "Run du -sh .",
  kind: "execute",
  command: "du -sh .",
  pending: true,
  options: [
    { id: "once", name: "Allow once", kind: "allow_once", allow: true },
    { id: "no", name: "Deny", kind: "reject_once", allow: false },
  ],
};

const groups = (state: string): PermissionClientState => ({
  supported: true,
  ready: true,
  groups: [{ groupId: "g1", state: "pending", items: [{ permissionId: "p1", state }] } as never],
  chatAllowance: false,
  loading: false,
  busy: false,
});

test("the card tells the pane when a deny's instructions open and close", async () => {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const drafts: boolean[] = [];
  await act(async () =>
    root.render(
      <PermissionCard
        permission={ask}
        harness="claude"
        onAnswer={() => Promise.resolve()}
        onDenyWithFeedback={() => Promise.resolve(true)}
        onDraft={(open) => drafts.push(open)}
      />,
    ),
  );
  try {
    const deny = host.querySelector<HTMLButtonElement>("[data-feedback-opener]")!;
    await act(async () => deny.click());
    expect(host.querySelector("textarea")).not.toBeNull();
    expect(drafts).toEqual([true]);
    await act(async () => root.unmount());
    expect(drafts).toEqual([true, false]);
  } finally {
    host.remove();
  }
});

test("an ask with instructions open stays on its card while its group still waits on it", () => {
  // The read landed: the pane's ask moved to the panel, so the snapshot names it no more.
  expect(heldOnCard(ask, undefined, groups("pending"))).toBe(ask);
  // Still the pane's ask: its current copy draws.
  const current = { ...ask, title: "Run du -sh . (again)" };
  expect(heldOnCard(ask, current, groups("pending"))).toBe(current);
  // Answered (here, by the group or elsewhere): the card goes.
  expect(heldOnCard(ask, undefined, groups("approved"))).toBeUndefined();
  expect(heldOnCard(ask, { ...ask, pending: false }, groups("pending"))).toBeUndefined();
  // Nothing typed: nothing held.
  expect(heldOnCard(undefined, undefined, groups("pending"))).toBeUndefined();
});
