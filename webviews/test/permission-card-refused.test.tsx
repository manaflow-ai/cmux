// l10n-allow-file: test fixture tool titles and option names, not shipped UI.
// An answer on the chat's permission card reaches the ask it was given for, and a refusal is never
// silent (the global inbox lane's audit, 2026-10-26). Before: the card sent its answer with `void`,
// so a refusal from acpmux (the ask already answered from a banner, the Feed or another window,
// withdrawn, or a policy change) was dropped. The keys were spent on that ask too: ⌥⌘1 and 1 did
// nothing more while it still waited, with nothing on screen to say why.
// - A refused answer says so on the card, and the keys answer that ask again.
// - An answer acpmux takes says nothing, and a held key never answers twice.
// - Each answer names its own ask: once the card shows the next ask, a key answers the next ask
//   with that ask's option, and the first ask's late refusal never shows on it.
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

const ask = (permissionId: string, allowId = `${permissionId}-yes`): AcpmuxPermission => ({
  permissionId,
  title: "Run rm -rf build",
  kind: "execute",
  command: "rm -rf build",
  pending: true,
  options: [
    { id: allowId, name: "Yes", kind: "allow_once", allow: true },
    { id: `${permissionId}-no`, name: "No", kind: "reject_once", allow: false },
  ],
});

type Sent = { permissionId: string; optionId: string; settle: { resolve(): void; reject(error: Error): void } };

async function mount(first: AcpmuxPermission) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const sent: Sent[] = [];
  const render = (permission: AcpmuxPermission) =>
    act(async () =>
      root.render(
        <PermissionCard
          permission={permission}
          harness="claude"
          onAnswer={(optionId) =>
            new Promise<void>((resolve, reject) => {
              sent.push({ permissionId: permission.permissionId, optionId, settle: { resolve, reject } });
            })
          }
        />,
      ),
    );
  await render(first);
  const key = (key: string) =>
    act(async () => void dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key })));
  const shortcut = (action: string) =>
    act(async () => void dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-${action}`)));
  const settle = (index: number, ok: boolean) =>
    act(async () => {
      const { settle } = sent[index]!;
      if (ok) settle.resolve();
      else settle.reject(new Error("no pending permission"));
      await Promise.resolve();
    });
  const alert = () => host.querySelector('[role="alert"]')?.textContent ?? undefined;
  return { host, sent, render, key, shortcut, settle, alert, unmount: () => act(async () => root.unmount()) };
}

test("a refused answer says so on the card, and the keys answer that ask again", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  expect(card.sent.map((s) => [s.permissionId, s.optionId])).toEqual([["p1", "p1-yes"]]);
  expect(card.alert()).toBeUndefined();
  await card.settle(0, false);
  expect(card.alert()).toBe(translate("permission.error.refused"));
  // The ask still waits (acpmux never took the answer): its keys work again.
  await card.shortcut("permissionAllowOnce");
  expect(card.sent.map((s) => [s.permissionId, s.optionId])).toEqual([
    ["p1", "p1-yes"],
    ["p1", "p1-yes"],
  ]);
  // A new answer clears the refusal until acpmux says how it went.
  expect(card.alert()).toBeUndefined();
  await card.unmount();
});

test("an answer acpmux takes shows nothing, and a held key never answers twice", async () => {
  const card = await mount(ask("p1"));
  await card.key("3");
  await card.key("3");
  await card.shortcut("permissionDeny");
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-no"]);
  await card.settle(0, true);
  expect(card.alert()).toBeUndefined();
  await card.key("1");
  expect(card.sent).toHaveLength(1);
  await card.unmount();
});

test("each answer names its own ask, and the ask before's late refusal never shows on the next", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  // acpmux took p1 and the agent asks again before p1's reply lands: the card now shows p2.
  await card.render(ask("p2", "p2-allow"));
  await card.key("1");
  expect(card.sent.map((s) => [s.permissionId, s.optionId])).toEqual([
    ["p1", "p1-yes"],
    ["p2", "p2-allow"],
  ]);
  await card.settle(0, false);
  expect(card.alert()).toBeUndefined();
  // p2's own refusal does show, and re-arms p2's keys only.
  await card.settle(1, false);
  expect(card.alert()).toBe(translate("permission.error.refused"));
  await card.key("1");
  expect(card.sent.at(-1)).toMatchObject({ permissionId: "p2", optionId: "p2-allow" });
  await card.unmount();
});
