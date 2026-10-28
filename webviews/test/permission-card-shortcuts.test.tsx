// l10n-allow-file: test fixture tool titles and option names, not shipped UI.
// The permission shortcuts (⌥⌘1 allow once, ⌥⌘2 allow for this chat, ⌥⌘3 deny) answer one ask:
// - An ask offering two options of one kind (Codex's decline and cancel, a reject once and a
//   reject always) answered ⌥⌘3 with the last of them and drew the keycap on both. The shortcut
//   now takes the first, and only that button shows it.
// - The single card and the permission group panel both listened for the same shortcuts, so with
//   a group and an ungrouped ask waiting (a command batch and an MCP call), one ⌥⌘1 allowed both.
//   While a group waits, the panel takes the shortcuts and the card shows none.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import type { PermissionClientState } from "../src/agent-session/acpmux/permissions/protocol";

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
const { cardTakesShortcuts } = await import("../src/agent-session/acpmux/permissionKeys");
const { SHORTCUT_ACTIONS, ShortcutsContext } = await import("../src/agent-session/acpmux/shortcuts");

const labels = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
};
const ask: AcpmuxPermission = {
  permissionId: "p1",
  title: "Run git push",
  kind: "execute",
  command: "git push",
  pending: true,
  options: [
    { id: "approved", name: "Yes", kind: "allow_once", allow: true },
    { id: "abort", name: "No, and tell Codex what to do differently", kind: "reject_once", allow: false },
    { id: "denied", name: "No, continue without running it", kind: "reject_always", allow: false },
  ],
};

async function mount(shortcuts?: boolean, permission: AcpmuxPermission = ask) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const answers: string[] = [];
  await act(async () =>
    root.render(
      <ShortcutsContext value={labels}>
        <PermissionCard
          permission={permission}
          harness="codex"
          onAnswer={(id) => answers.push(id)}
          {...(shortcuts === undefined ? {} : { shortcuts })}
        />
      </ShortcutsContext>,
    ),
  );
  const press = (action: string) =>
    act(async () => void dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-${action}`)));
  const keycaps = () =>
    [...host.querySelectorAll("button")]
      .filter((button) => button.querySelector("kbd"))
      .map((button) => `${button.getAttribute("aria-label")}: ${button.querySelector("kbd")!.textContent}`);
  return { host, answers, press, keycaps, unmount: () => act(async () => root.unmount()) };
}

test("deny answers with the first deny option, and only its button shows the keycap", async () => {
  const card = await mount();
  expect(card.keycaps()).toEqual(["Allow once: ⌥⌘1", "Deny: ⌥⌘3"]);
  await card.press("permissionDeny");
  expect(card.answers).toEqual(["abort"]);
  await card.unmount();
});

// Leo 2026-10-25: the buttons went short ("Always allow", not its whole rule); the keys stay.
test("short buttons keep ⌥⌘1, ⌥⌘2 and ⌥⌘3, and an extra option draws no key", async () => {
  const card = await mount(undefined, {
    ...ask,
    permissionId: "p-rule",
    rule: "Allow Bash(git push:*), Bash(git fetch:*) for this session",
    options: [
      { id: "approved", name: "Yes", kind: "allow_once", allow: true },
      { id: "session", name: "Yes, and don't ask again for `git push`", kind: "allow_always", allow: true },
      ...ask.options.slice(1),
    ],
  });
  expect(card.keycaps()).toEqual(["Allow once: ⌥⌘1", "Always allow: ⌥⌘2", "Deny: ⌥⌘3"]);
  // Leo 2026-10-25, "just make it good? incl. the symbol hints": the hint is decoration, its
  // modifiers a fainter span before the key, and the button's name stays its label.
  const hints = [...card.host.querySelectorAll(".acpmux-permission-action-shortcut")];
  expect(hints.map((hint) => hint.getAttribute("aria-hidden"))).toEqual(["true", "true", "true"]);
  expect(hints.map((hint) => hint.querySelector(".acpmux-permission-action-modifiers")?.textContent)).toEqual([
    "⌥⌘",
    "⌥⌘",
    "⌥⌘",
  ]);
  expect(
    [...card.host.querySelectorAll("button[aria-keyshortcuts]")].map((b) => b.getAttribute("aria-keyshortcuts")),
  ).toEqual(["⌥⌘1", "⌥⌘2", "⌥⌘3"]);
  await card.press("permissionAllowChat");
  expect(card.answers).toEqual(["session"]);
  await card.unmount();
});

test("a card that yields the shortcuts ignores them and shows no keycaps", async () => {
  const card = await mount(false);
  expect(card.keycaps()).toEqual([]);
  await card.press("permissionAllowOnce");
  await card.press("permissionDeny");
  expect(card.answers).toEqual([]);
  await card.unmount();
});

test("the card yields the shortcuts while a permission group waits", () => {
  const state = (groups: { state: string }[], supported = true) =>
    ({
      supported,
      ready: true,
      groups,
      chatAllowance: false,
      loading: false,
      busy: false,
    }) as unknown as PermissionClientState;
  expect(cardTakesShortcuts(undefined)).toBe(true);
  expect(cardTakesShortcuts(state([]))).toBe(true);
  expect(cardTakesShortcuts(state([{ state: "resolved" }]))).toBe(true);
  expect(cardTakesShortcuts(state([{ state: "pending" }]))).toBe(false);
  expect(cardTakesShortcuts(state([{ state: "collecting" }]))).toBe(false);
  expect(cardTakesShortcuts(state([{ state: "pending" }], false))).toBe(true);
});
