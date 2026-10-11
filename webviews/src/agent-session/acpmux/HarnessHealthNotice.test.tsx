// Agent CLI health in a chat (cx-ny85): a chat whose agent CLI is signed out says so with a Log In
// that runs the agent's login in a terminal tab; an outdated one offers its own update the same
// way, Not Now for this chat and Skip This Version for good. An update that needs sudo, an
// up-to-date or unknown one shows nothing (Settings > Agents has the details).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { type HarnessHealth, HarnessHealthNotice } from "./HarnessHealthNotice";

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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Opened = { kind: string; text: string; cwd?: string; run: boolean };

async function render(
  container: HTMLElement,
  health: HarnessHealth | undefined,
  opened: Opened[] = [],
  harness = "codex",
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
      />,
    );
  });
  return opened;
}

const notice = (container: HTMLElement) => container.querySelector<HTMLElement>("[data-harness-notice]");
async function press(container: HTMLElement, action: string) {
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

test("an outdated agent CLI offers its own update; Skip This Version stays skipped until a newer one", async () => {
  const container = installDom();
  const opened = await render(container, outdated);
  expect(notice(container)?.dataset.harnessNotice).toBe("outdated");
  await press(container, "update");
  expect(opened).toEqual([{ kind: "terminal", text: "npm install -g @openai/codex@latest", cwd: "/work", run: true }]);
  await press(container, "skip");
  expect(notice(container)).toBeNull();
  // Another chat, same version: still skipped. A newer version asks again.
  await act(async () => root!.unmount());
  root = undefined;
  await render(container, outdated);
  expect(notice(container)).toBeNull();
  await render(container, { ...outdated, latest: "0.5.0" });
  expect(notice(container)?.dataset.harnessNotice).toBe("outdated");
});

test("nothing shows for an update that needs sudo, a current CLI, or sign-in the daemon cannot tell", async () => {
  const container = installDom();
  await render(container, {
    ...outdated,
    update: { command: "sudo npm install -g @openai/codex@latest", elevated: true },
  });
  expect(notice(container)).toBeNull();
  await render(container, { ...outdated, outdated: false });
  expect(notice(container)).toBeNull();
  await render(container, { id: "codex", auth: "unknown", login: "codex login" });
  expect(notice(container)).toBeNull();
  await render(container, { ...signedOut, login: null });
  expect(notice(container)).toBeNull();
  await render(container, undefined);
  expect(notice(container)).toBeNull();
});

test("a chat that switched agent never shows the previous agent's notice", async () => {
  const container = installDom();
  // The chat is on Claude now; Codex's row has not been replaced yet.
  const opened = await render(container, signedOut, [], "claude");
  expect(notice(container)).toBeNull();
  expect(opened).toEqual([]);
});
