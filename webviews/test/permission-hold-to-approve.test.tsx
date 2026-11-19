// l10n-allow-file: test fixture asks, commands and option names, not shipped UI.
// Hold to approve (permissions/holdToApprove.experiment.ts, off by default): with it on, the
// permission card's allow and the grouped panel's allow answer only after the pointer, Return or the
// answer's letter stays down for the hold time; a click or an early release answers nothing; deny never
// holds. With it off (no `hold` prop, no experiment key) the card's click answers at once, as today.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM(`<!doctype html><div id=root></div>`, {
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
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent|MouseEvent)/.test(key) && !(key in globals),
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
const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
type PermissionClientState = import("../src/agent-session/acpmux/permissions/protocol").PermissionClientState;

const doc = dom.window.document;
const host = doc.getElementById("root")!;
const HOLD_MS = 60;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const options: AcpmuxPermission["options"] = [
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "always", name: "Always Allow", kind: "allow_always", allow: true },
  { id: "reject", name: "Reject", kind: "reject_once", allow: false },
];
const ask = (permissionId: string, command: string): AcpmuxPermission => ({
  permissionId,
  title: `Run ${command}`,
  kind: "execute",
  command,
  pending: true,
  options,
});

type Hold = { scope: "off" | "all" | "destructive"; durationMs: number };
async function mountCard(permission: AcpmuxPermission, hold?: Hold) {
  const root = createRoot(host);
  const answers: string[] = [];
  await act(async () =>
    root.render(
      <PermissionCard permission={permission} harness="claude" hold={hold} onAnswer={(id) => answers.push(id)} />,
    ),
  );
  const allow = host.querySelector<HTMLButtonElement>(".acpmux-permission-buttons .acpmux-permission-primary")!;
  const deny = host.querySelector<HTMLButtonElement>(".acpmux-permission-buttons .acpmux-permission-deny")!;
  return { root, answers, allow, deny };
}

const fire = (target: Element, type: string, init: Record<string, unknown> = {}) =>
  act(async () => {
    const Event = type.startsWith("key") ? dom.window.KeyboardEvent : dom.window.MouseEvent;
    target.dispatchEvent(new Event(type, { bubbles: true, cancelable: true, button: 0, ...init }));
  });
const wait = (ms: number) => act(async () => void (await sleep(ms)));

test("off: the allow is today's button, and a click answers at once", async () => {
  const card = await mountCard(ask("off", "rm -rf build"));
  expect(card.allow.hasAttribute("data-hold")).toBe(false);
  expect(card.allow.querySelector(".acpmux-hold-ring")).toBeNull();
  await fire(card.allow, "click", { detail: 1 });
  expect(card.answers).toEqual(["allow"]);
  await act(async () => card.root.unmount());
});

test("on: a click answers nothing; a press held through the hold time answers once", async () => {
  const card = await mountCard(ask("held", "npm test"), { scope: "all", durationMs: HOLD_MS });
  expect(card.allow.getAttribute("data-hold")).toBe("idle");
  expect(card.allow.querySelector(".acpmux-hold-ring")).not.toBeNull();
  expect(card.allow.getAttribute("aria-description")).toBe("Hold to allow");
  await fire(card.allow, "click", { detail: 1 });
  expect(card.answers).toEqual([]);
  await fire(card.allow, "pointerdown");
  expect(card.allow.getAttribute("data-hold")).toBe("holding");
  await wait(HOLD_MS + 40);
  expect(card.answers).toEqual(["allow"]);
  await fire(card.allow, "pointerup");
  await fire(card.allow, "click", { detail: 1 });
  expect(card.answers).toEqual(["allow"]);
  await act(async () => card.root.unmount());
});

test("on: letting go early answers nothing and empties the ring", async () => {
  const card = await mountCard(ask("early", "npm test"), { scope: "all", durationMs: HOLD_MS });
  await fire(card.allow, "pointerdown");
  await wait(HOLD_MS / 3);
  await fire(card.allow, "pointerup");
  expect(card.allow.getAttribute("data-hold")).toBe("idle");
  await wait(HOLD_MS + 40);
  expect(card.answers).toEqual([]);
  await act(async () => card.root.unmount());
});

test("on: the card's y key held answers; released early it does not; n still denies at once", async () => {
  const card = await mountCard(ask("keys", "npm test"), { scope: "all", durationMs: HOLD_MS });
  await fire(doc.body, "keydown", { key: "y", code: "KeyY" });
  await wait(HOLD_MS / 3);
  await fire(doc.body, "keyup", { key: "y", code: "KeyY" });
  await wait(HOLD_MS + 40);
  expect(card.answers).toEqual([]);
  await fire(doc.body, "keydown", { key: "y", code: "KeyY" });
  // A held key repeats: the repeats neither restart nor answer.
  await fire(doc.body, "keydown", { key: "y", code: "KeyY", repeat: true });
  await wait(HOLD_MS + 40);
  expect(card.answers).toEqual(["allow"]);
  await act(async () => card.root.unmount());
  const second = await mountCard(ask("deny", "npm test"), { scope: "all", durationMs: HOLD_MS });
  expect(second.deny.hasAttribute("data-hold")).toBe(false);
  await fire(doc.body, "keydown", { key: "n", code: "KeyN" });
  expect(second.answers).toEqual(["reject"]);
  await act(async () => second.root.unmount());
});

test("on: Return held on the focused allow answers; its click does not answer twice", async () => {
  const card = await mountCard(ask("return", "npm test"), { scope: "all", durationMs: HOLD_MS });
  card.allow.focus();
  await fire(card.allow, "keydown", { key: "Enter", code: "Enter" });
  await wait(HOLD_MS + 40);
  await fire(card.allow, "keyup", { key: "Enter", code: "Enter" });
  expect(card.answers).toEqual(["allow"]);
  await act(async () => card.root.unmount());
});

test("only destructive: a benign command allows on click, rm -rf holds", async () => {
  const benign = await mountCard(ask("benign", "npm test"), { scope: "destructive", durationMs: HOLD_MS });
  expect(benign.allow.hasAttribute("data-hold")).toBe(false);
  await fire(benign.allow, "click", { detail: 1 });
  expect(benign.answers).toEqual(["allow"]);
  await act(async () => benign.root.unmount());
  const risky = await mountCard(ask("risky", "rm -rf build"), { scope: "destructive", durationMs: HOLD_MS });
  expect(risky.allow.getAttribute("data-hold")).toBe("idle");
  await fire(risky.allow, "click", { detail: 1 });
  expect(risky.answers).toEqual([]);
  await act(async () => risky.root.unmount());
});

const panelState = (command: string): PermissionClientState => ({
  supported: true,
  ready: true,
  chatAllowance: false,
  loading: false,
  busy: false,
  groups: [
    {
      groupId: "g1",
      sessionId: "s1",
      turnId: "t1",
      revision: 1,
      state: "pending",
      decision: null,
      decisions: ["allow_once", "allow_chat", "deny"],
      items: [
        {
          permissionId: "p1",
          state: "pending",
          request: { toolCall: { kind: "execute", title: command, rawInput: { command } } },
        },
      ],
    },
  ],
});

test("the grouped panel: under hold its Allow answers only after the hold, Deny at once", async () => {
  const root = createRoot(host);
  const sent: string[] = [];
  const render = (scope: Hold["scope"]) =>
    act(async () =>
      root.render(
        <PermissionPanel
          state={panelState("git push --force")}
          working
          hold={{ scope, durationMs: HOLD_MS }}
          onRespond={(_group, _revision, decision) => sent.push(decision)}
          onRetry={() => undefined}
          onRevoke={() => undefined}
          onRefresh={() => undefined}
        />,
      ),
    );
  await render("destructive");
  const allow = host.querySelector<HTMLButtonElement>(".acpmux-ask-action.is-primary")!;
  expect(allow.getAttribute("data-hold")).toBe("idle");
  await fire(allow, "click", { detail: 1 });
  expect(sent).toEqual([]);
  await fire(allow, "pointerdown");
  await wait(HOLD_MS + 40);
  expect(sent).toEqual(["allow_once"]);
  const deny = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-ask-action")].at(-1)!;
  expect(deny.hasAttribute("data-hold")).toBe(false);
  await fire(deny, "click", { detail: 1 });
  expect(sent).toEqual(["allow_once", "deny"]);
  // Off: the same Allow answers on its click.
  await render("off");
  const plain = host.querySelector<HTMLButtonElement>(".acpmux-ask-action.is-primary")!;
  expect(plain.hasAttribute("data-hold")).toBe(false);
  await fire(plain, "click", { detail: 1 });
  expect(sent).toEqual(["allow_once", "deny", "allow_once"]);
  await act(async () => root.unmount());
});
