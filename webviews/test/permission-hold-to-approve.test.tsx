// l10n-allow-file: test fixture asks, commands and option names, not shipped UI.
// Hold to approve (permissions/holdToApprove.experiment.ts, off by default): with it on, the
// permission card's allow and the grouped panel's allow answer only after the pointer, Return or the
// answer's letter stays down for the hold time; a click or an early release answers nothing; deny never
// holds. With it off (no `hold` prop, no experiment key) the card's click answers at once, as today.
import { afterAll, afterEach, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM(
  `<!doctype html><div id=root></div>
  <div class="acpmux-composer-prompt"><div class="acpmux-md-root"><div id=editor contenteditable="true" tabindex="-1"></div></div></div>`,
  {
    url: "http://localhost/",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  },
);
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
const editor = doc.getElementById("editor")!;
const HOLD_MS = 60;

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
// The hold's time is the behavior under test: a fake clock moves it (its timers, frames and
// performance.now), so a loaded runner that wakes late cannot fill or miss a hold.
beforeEach(() => void jest.useFakeTimers());
afterEach(() => void jest.useRealTimers());
const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

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

/// A card the test can rerender with another ask, as the pane does when the next ask arrives.
async function liveCard(first: AcpmuxPermission, hold: Hold) {
  const root = createRoot(host);
  const answers: string[] = [];
  const show = (permission: AcpmuxPermission) =>
    act(async () =>
      root.render(
        <PermissionCard
          permission={permission}
          harness="claude"
          hold={hold}
          onAnswer={(id) => answers.push(`${permission.permissionId}:${id}`)}
        />,
      ),
    );
  await show(first);
  const allow = () => host.querySelector<HTMLButtonElement>(".acpmux-permission-buttons .acpmux-permission-primary")!;
  return { root, answers, show, allow };
}

test("F1: a hold started on ask A never approves the ask B that replaces it; B needs its own press", async () => {
  const card = await liveCard(ask("ask-a", "npm test"), { scope: "all", durationMs: HOLD_MS });
  // y goes down on A and stays down while A is replaced by B.
  await fire(doc.body, "keydown", { key: "y", code: "KeyY" });
  expect(card.allow().getAttribute("data-hold")).toBe("holding");
  await card.show(ask("ask-b", "npm run build"));
  expect(card.allow().getAttribute("data-hold")).toBe("idle");
  await wait(HOLD_MS * 2);
  expect(card.answers).toEqual([]);
  await fire(doc.body, "keyup", { key: "y", code: "KeyY" });
  // A pointer hold on A, then B: the same.
  await card.show(ask("ask-c", "npm test"));
  await fire(card.allow(), "pointerdown");
  await card.show(ask("ask-d", "npm test"));
  await wait(HOLD_MS * 2);
  expect(card.answers).toEqual([]);
  await fire(card.allow(), "pointerup");
  // A fresh press on the ask shown answers that ask only.
  await fire(doc.body, "keydown", { key: "y", code: "KeyY" });
  await wait(HOLD_MS + 40);
  await fire(doc.body, "keyup", { key: "y", code: "KeyY" });
  expect(card.answers).toEqual(["ask-d:allow"]);
  await act(async () => card.root.unmount());
});

test("F1: the panel's hold ends when its group's revision changes", async () => {
  const root = createRoot(host);
  const sent: string[] = [];
  const render = (revision: number) =>
    act(async () => {
      const state = panelState("rm -rf build");
      state.groups[0]!.revision = revision;
      root.render(
        <PermissionPanel
          state={state}
          working
          hold={{ scope: "all", durationMs: HOLD_MS }}
          onRespond={(group, at, decision) => sent.push(`${group}@${at}:${decision}`)}
          onRetry={() => undefined}
          onRevoke={() => undefined}
          onRefresh={() => undefined}
        />,
      );
    });
  await render(1);
  await fire(host.querySelector(".acpmux-ask-action.is-primary")!, "pointerdown");
  await render(2);
  await wait(HOLD_MS * 2);
  expect(sent).toEqual([]);
  const allow = host.querySelector(".acpmux-ask-action.is-primary")!;
  await fire(allow, "pointerup");
  await fire(allow, "pointerdown");
  await wait(HOLD_MS + 40);
  expect(sent).toEqual(["g1@2:allow_once"]);
  await act(async () => root.unmount());
});

test("F2: dragging off Allow while it is pressed lets go and answers nothing", async () => {
  const card = await mountCard(ask("drag", "npm test"), { scope: "all", durationMs: HOLD_MS });
  card.allow.getBoundingClientRect = () =>
    ({ left: 10, right: 90, top: 10, bottom: 40, width: 80, height: 30, x: 10, y: 10, toJSON: () => "" }) as DOMRect;
  await fire(card.allow, "pointerdown", { clientX: 20, clientY: 20 });
  // Moving inside keeps the hold.
  await fire(card.allow, "pointermove", { clientX: 80, clientY: 30 });
  expect(card.allow.getAttribute("data-hold")).toBe("holding");
  // Captured, the pointer's moves still reach the button once it is off it.
  await fire(card.allow, "pointermove", { clientX: 200, clientY: 30 });
  expect(card.allow.getAttribute("data-hold")).toBe("idle");
  await wait(HOLD_MS * 2);
  await fire(card.allow, "pointerup", { clientX: 200, clientY: 30 });
  expect(card.answers).toEqual([]);
  await act(async () => card.root.unmount());
});

test("F3: the window losing focus ends a pointer hold and a key hold", async () => {
  const card = await mountCard(ask("blur", "npm test"), { scope: "all", durationMs: HOLD_MS });
  await fire(card.allow, "pointerdown");
  await act(async () => void dom.window.dispatchEvent(new dom.window.Event("blur")));
  expect(card.allow.getAttribute("data-hold")).toBe("idle");
  await fire(doc.body, "keydown", { key: "y", code: "KeyY" });
  expect(card.allow.getAttribute("data-hold")).toBe("holding");
  await act(async () => void dom.window.dispatchEvent(new dom.window.Event("blur")));
  await wait(HOLD_MS * 2);
  expect(card.answers).toEqual([]);
  await act(async () => card.root.unmount());
});

test("F3: a key hold from the composer ends when the composer loses focus", async () => {
  const card = await mountCard(ask("origin", "npm test"), { scope: "all", durationMs: HOLD_MS });
  editor.focus();
  await fire(editor, "keydown", { key: "y", code: "KeyY" });
  expect(card.allow.getAttribute("data-hold")).toBe("holding");
  await act(async () => editor.blur());
  expect(card.allow.getAttribute("data-hold")).toBe("idle");
  await wait(HOLD_MS * 2);
  expect(card.answers).toEqual([]);
  await act(async () => card.root.unmount());
});

test("F4: the held key's repeats are the hold's and type nothing", async () => {
  const card = await mountCard(ask("repeat", "npm test"), { scope: "all", durationMs: HOLD_MS * 4 });
  editor.focus();
  await fire(editor, "keydown", { key: "y", code: "KeyY" });
  const repeat = new dom.window.KeyboardEvent("keydown", {
    key: "y",
    code: "KeyY",
    repeat: true,
    bubbles: true,
    cancelable: true,
  });
  await act(async () => void editor.dispatchEvent(repeat));
  expect(repeat.defaultPrevented).toBe(true);
  await fire(editor, "keyup", { key: "y", code: "KeyY" });
  editor.blur();
  await act(async () => card.root.unmount());
});

/// Starts a hold whose completion timer the test keeps: `setTimeout` for the hold's own duration hands
/// its callback to the test (clearTimeout of it then does nothing), so the timer can fire after the
/// cancel the identity change ran, as a timer due in the same tick as the change would.
async function captureHoldTimer(start: () => Promise<void>, durationMs: number) {
  const real = globalThis.setTimeout;
  let captured: (() => void) | undefined;
  globalThis.setTimeout = ((callback: () => void, delay?: number, ...rest: unknown[]) => {
    if (delay === durationMs && !captured) {
      captured = callback;
      return 0 as unknown as ReturnType<typeof setTimeout>;
    }
    return real(callback, delay, ...rest);
  }) as typeof setTimeout;
  try {
    await start();
  } finally {
    globalThis.setTimeout = real;
  }
  if (!captured) throw new Error("the hold set no timer for its duration");
  return captured;
}

test("the timer's last-moment check: a hold whose timer fires after its ask changed answers nothing", async () => {
  const DURATION = 777;
  const card = await liveCard(ask("late-a", "npm test"), { scope: "all", durationMs: DURATION });
  const fireTimer = await captureHoldTimer(() => fire(card.allow(), "pointerdown"), DURATION);
  // B replaces A before A's timer runs; the cancel cannot stop the timer (it is the test's).
  await card.show(ask("late-b", "npm test"));
  await act(async () => fireTimer());
  expect(card.answers).toEqual([]);
  expect(card.allow().getAttribute("data-hold")).toBe("idle");
  await fire(card.allow(), "pointerup");
  // The same timer on an unchanged ask answers it: the check lets the right ask through.
  const again = await captureHoldTimer(() => fire(card.allow(), "pointerdown"), DURATION);
  await act(async () => again());
  expect(card.answers).toEqual(["late-b:allow"]);
  await fire(card.allow(), "pointerup");
  await act(async () => card.root.unmount());
});
