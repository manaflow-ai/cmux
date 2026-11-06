// l10n-allow-file: test fixture tool titles and option names, not shipped UI.
// A peer's chat takes only a one-time Allow and a Deny from this Mac (acpmux mac_approvers.rs): a
// lasting grant is never accepted from a Mac. Before, its card offered Always allow like a local
// chat's, the click went to the peer and came back refused, and the card said "That answer didn't
// go through" while the ask was still live (Leo, 2026-11-03: "this is bad and weird + shouldn't even
// happen"). Now:
// - Always allow stays on the card, disabled, with its tooltip naming why; its key hint is gone.
// - ⌥⌘2 sends nothing on a peer's card; Allow once and Deny still answer.
// - A local chat's card is unchanged.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";

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
afterAll(() => {
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
const { translate } = await import("../src/agent-session/acpmux/i18n");

const ask: AcpmuxPermission = {
  permissionId: "p1",
  title: "Run du -sh .",
  kind: "execute",
  command: "du -sh .",
  pending: true,
  options: [
    { id: "once", name: "Allow once", kind: "allow_once", allow: true },
    { id: "always", name: "Always allow", kind: "allow_always", allow: true },
    { id: "no", name: "Deny", kind: "reject_once", allow: false },
  ],
};

async function mount(alwaysAtSource: boolean) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const sent: string[] = [];
  await act(async () =>
    root.render(
      <PermissionCard
        permission={ask}
        harness="claude"
        alwaysAtSource={alwaysAtSource}
        onAnswer={(optionId) => {
          sent.push(optionId);
          return Promise.resolve();
        }}
      />,
    ),
  );
  const button = (label: string) =>
    [...host.querySelectorAll("button")].find((b) => b.getAttribute("aria-label") === label);
  const shortcut = (action: string) =>
    act(async () => void dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-${action}`)));
  const unmount = () => act(async () => root.unmount()).then(() => host.remove());
  return { button, shortcut, sent, unmount };
}

test("a peer's card keeps Always allow, disabled and saying why, and its key sends nothing", async () => {
  const card = await mount(true);
  try {
    const always = card.button(translate("permission.alwaysAllow"))!;
    expect(always).toBeDefined();
    expect(always.disabled).toBe(true);
    expect(always.title).toBe(translate("permission.alwaysAtSource"));
    expect(always.getAttribute("aria-keyshortcuts")).toBeNull();
    always.click();
    await card.shortcut("permissionAllowChat");
    expect(card.sent).toEqual([]);
    // Allow once still answers from this Mac.
    await act(async () => card.button(translate("permission.allowOnce"))!.click());
    expect(card.sent).toEqual(["once"]);
  } finally {
    await card.unmount();
  }
});

test("a local chat's card keeps Always allow live", async () => {
  const card = await mount(false);
  try {
    const always = card.button(translate("permission.alwaysAllow"))!;
    expect(always.disabled).toBe(false);
    await act(async () => always.click());
    expect(card.sent).toEqual(["always"]);
  } finally {
    await card.unmount();
  }
});
