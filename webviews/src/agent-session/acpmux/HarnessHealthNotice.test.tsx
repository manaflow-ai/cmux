// Agent CLI health in a chat (cx-ny85): a chat whose agent CLI is signed out says so with a Log In
// that runs the agent's login in a terminal tab; an outdated one draws no line, it hands the model
// chip its offer (hq#2569 #12): Update runs in place through the host (`harness.update`,
// cx-1mbnu), then the line offers Restart Chat (`harness.restart`); Skip This Version for good. An update that needs sudo, an up-to-date or unknown one shows
// nothing (Settings > Agents has the details).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { type HarnessHealth, HarnessHealthNotice, type UpdateOffer } from "./HarnessHealthNotice";

let dom: JSDOM | undefined;
let root: Root | undefined;
/// What the notice hands the model chip: the update on offer, if any.
let offer: UpdateOffer | undefined;
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
    saved.set(key, scope[key]);
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
  offer = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Opened = { kind: string; text: string; cwd?: string; run: boolean };
type Call = {
  method: string;
  params: Record<string, unknown>;
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
};

/// The host's calls, each answered by the test (`resolve`/`reject`), the way the native updater takes minutes.
function host() {
  const calls: Call[] = [];
  const native = (method: string, params: Record<string, unknown>) =>
    new Promise<unknown>((resolve, reject) => calls.push({ method, params, resolve, reject }));
  return { calls, native };
}

async function render(
  container: HTMLElement,
  health: HarnessHealth | undefined,
  opened: Opened[] = [],
  harness = "codex",
  native: (method: string, params: Record<string, unknown>) => Promise<unknown> = () => new Promise(() => undefined),
  extra: { turnRunning?: boolean; onUpdated?: () => void } = {},
) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <HarnessHealthNotice
        health={health}
        harness={harness}
        name="Codex"
        cwd="/work"
        open={(params) => opened.push(params)}
        native={native}
        onOffer={(next) => (offer = next)}
        {...extra}
      />,
    );
  });
  return opened;
}

const text = (container: HTMLElement) => notice(container)?.textContent ?? "";
const button = (container: HTMLElement, action: string) =>
  container.querySelector<HTMLButtonElement>(`[data-notice-action="${action}"]`);
async function answer(call: Call | undefined, value: unknown, failed = false) {
  expect(call).toBeDefined();
  await act(async () => (failed ? call!.reject(value) : call!.resolve(value)));
}

const notice = (container: HTMLElement) => container.querySelector<HTMLElement>("[data-harness-notice]");
async function press(container: HTMLElement, action: string) {
  // The offer's Update and Skip This Version live on the model chip.
  if (action === "update" || action === "skip") {
    expect(offer).toBeDefined();
    const chosen = offer!;
    await act(async () => (action === "update" ? chosen.update() : chosen.skip()));
    return;
  }
  await act(async () => container.querySelector<HTMLButtonElement>(`[data-notice-action="${action}"]`)!.click());
}

const signedOut: HarnessHealth = { id: "codex", auth: "signedOut", login: "codex login", outdated: false };
const outdated: HarnessHealth = {
  id: "codex",
  auth: "signedIn",
  version: "0.3.1",
  latest: "0.4.0",
  outdated: true,
  update: { command: "npm install -g @openai/codex@latest", elevated: false },
};

test("a signed-out agent CLI says so, and Log In runs its login in a terminal tab of the chat's folder", async () => {
  const container = installDom();
  const opened = await render(container, signedOut);
  expect(notice(container)?.dataset.harnessNotice).toBe("signedOut");
  // An <output>: announced as a status, never an alert.
  expect(notice(container)?.tagName).toBe("OUTPUT");
  await press(container, "login");
  expect(opened).toEqual([{ kind: "terminal", text: "codex login", cwd: "/work", run: true }]);
  // Not Now hides it for this chat.
  await press(container, "dismiss");
  expect(notice(container)).toBeNull();
});

test("an outdated agent CLI draws no line: the model chip offers its update; Skip This Version stays skipped until a newer one", async () => {
  const container = installDom();
  await render(container, outdated);
  expect(notice(container)).toBeNull();
  expect(offer).toMatchObject({ harness: "codex", agent: "Codex", version: "0.3.1", latest: "0.4.0" });
  await press(container, "skip");
  expect(offer).toBeUndefined();
  expect(notice(container)).toBeNull();
  // Another chat, same version: still skipped. A newer version offers again.
  await act(async () => root!.unmount());
  root = undefined;
  await render(container, outdated);
  expect(offer).toBeUndefined();
  await render(container, { ...outdated, latest: "0.5.0" });
  expect(offer?.latest).toBe("0.5.0");
  expect(notice(container)).toBeNull();
});

test("nothing shows for an update that needs sudo, a current CLI, or sign-in without a recovery command", async () => {
  const container = installDom();
  await render(container, {
    ...outdated,
    update: { command: "sudo npm install -g @openai/codex@latest", elevated: true },
  });
  expect(notice(container)).toBeNull();
  await render(container, { ...outdated, outdated: false });
  expect(notice(container)).toBeNull();
  const opened = await render(container, { id: "codex", auth: "unknown", login: "codex login" });
  expect(notice(container)?.dataset.harnessNotice).toBe("signedOut");
  await press(container, "login");
  expect(opened).toEqual([{ kind: "terminal", text: "codex login", cwd: "/work", run: true }]);
  await press(container, "dismiss");
  expect(notice(container)).toBeNull();
  await render(container, { ...signedOut, login: null });
  expect(notice(container)).toBeNull();
  await render(container, undefined);
  expect(notice(container)).toBeNull();
  expect(offer).toBeUndefined();
});

test("a chat that switched agent never shows the previous agent's notice", async () => {
  const container = installDom();
  // The chat is on Claude now; Codex's row has not been replaced yet.
  const opened = await render(container, signedOut, [], "claude");
  expect(notice(container)).toBeNull();
  expect(opened).toEqual([]);
});

test("Update runs the host's updater for this agent and says so while it works, without a terminal tab", async () => {
  const container = installDom();
  const { calls, native } = host();
  const opened = await render(container, outdated, [], "codex", native);
  await press(container, "update");
  expect(calls.map(({ method, params }) => ({ method, params }))).toEqual([
    { method: "harness.update", params: { id: "codex" } },
  ]);
  expect(opened).toEqual([]);
  expect(text(container)).toContain("Updating Codex…");
  // Started, it is no longer an offer; Not Now waits, or it would lose the Restart Chat.
  expect(offer).toBeUndefined();
  expect(button(container, "dismiss")?.disabled).toBe(true);
});

test("Restart Chat stays after the update even when the agent's health, read again, is current", async () => {
  const container = installDom();
  const { calls, native } = host();
  await render(container, outdated, [], "codex", native);
  await press(container, "update");
  await answer(calls[0], { ok: true, version: "0.4.0" });
  // A reconnect reads health again: the CLI is current now, but this chat still runs 0.3.1.
  await render(container, { ...outdated, version: "0.4.0", outdated: false, update: null }, [], "codex", native);
  expect(text(container)).toContain("Codex 0.4.0 is installed. Restart the chat to use it.");
  expect(button(container, "restart")).not.toBeNull();
});

test("a restart that failed says so and keeps Restart Chat", async () => {
  const container = installDom();
  const { calls, native } = host();
  await render(container, outdated, [], "codex", native);
  await press(container, "update");
  await answer(calls[0], { ok: true, version: "0.4.0" });
  await press(container, "restart");
  await answer(calls[1], { restarted: 0, after_turn: 0, failed: 1, error: "the agent did not start" });
  expect(text(container)).toContain("Couldn't restart the chat: the agent did not start");
  expect(button(container, "restart")?.disabled).toBe(false);
});

test("a finished update offers Restart Chat, which restarts the chat on the new version", async () => {
  const container = installDom();
  const { calls, native } = host();
  let rechecks = 0;
  await render(container, outdated, [], "codex", native, { onUpdated: () => rechecks++ });
  await press(container, "update");
  await answer(calls[0], { ok: true, version: "0.4.0" });
  expect(text(container)).toContain("Codex 0.4.0 is installed. Restart the chat to use it.");
  await press(container, "restart");
  expect(calls[1]?.method).toBe("harness.restart");
  await answer(calls[1], { restarted: 1, after_turn: 0 });
  expect(notice(container)).toBeNull();
  expect(rechecks).toBe(1);
});

test("a chat mid-turn restarts when the turn ends; the card says so, then goes away", async () => {
  const container = installDom();
  const { calls, native } = host();
  let rechecks = 0;
  const onUpdated = () => rechecks++;
  await render(container, outdated, [], "codex", native, { turnRunning: true, onUpdated });
  await press(container, "update");
  await answer(calls[0], { ok: true, version: "0.4.0" });
  await press(container, "restart");
  await answer(calls[1], { restarted: 0, after_turn: 1 });
  expect(text(container)).toContain("The chat restarts on 0.4.0 when this turn ends.");
  await render(container, outdated, [], "codex", native, { turnRunning: false, onUpdated });
  expect(notice(container)).toBeNull();
  expect(rechecks).toBe(1);
});

test("a failed update says why inline, and Try Again runs it again", async () => {
  const container = installDom();
  const { calls, native } = host();
  await render(container, outdated, [], "codex", native);
  await press(container, "update");
  await answer(calls[0], { ok: false, error: "npm exited with status 1" });
  expect(text(container)).toContain("Couldn't update Codex: npm exited with status 1");
  await press(container, "retry");
  expect(calls[1]?.method).toBe("harness.update");
  expect(text(container)).toContain("Updating Codex…");
  // A refused call (an old host) says what it can.
  await answer(calls[1], new Error(""), true);
  expect(text(container)).toContain("Couldn't update Codex: The update didn't finish.");
  await press(container, "retry");
  await answer(calls[2], new Error("Not supported here."), true);
  expect(text(container)).toContain("Couldn't update Codex: Not supported here.");
  expect(button(container, "dismiss")).not.toBeNull();
});
