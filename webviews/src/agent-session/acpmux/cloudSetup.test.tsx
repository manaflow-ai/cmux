// l10n-allow-file: test fixture prompts and model ids, not shipped UI.
// Cloud first use (cloudSetup.ts, conversation/CloudSetupCard.tsx): a start no connection serves shows
// Set up Cloud naming the model; a button runs its way in on this Mac, and the start goes again by
// itself once a connection serves the family.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { CloudStartView } from "./CloudStartView";
import { cloudStartEnded, cloudStartSignedIn, type CloudStartProgress } from "./cloudStartProgress";
import { cloudPickExtras, startCloudChat } from "./cloudRun";
import { cloudSetupActions, readCloudSetupNeed, waitForCloudSetUp, type CloudSetupAction } from "./cloudSetup";
import { startAfterSignIn } from "./cloudSignIn";
import { translate } from "./i18n";
import setupGallery from "./CloudSetup.gallery";

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
    "MouseEvent",
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
    MouseEvent: dom.window.MouseEvent,
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

const begun: CloudStartProgress = { key: "k", task: "fix the build", state: "starting", folder: "paint" };
const refused = {
  ok: false as const,
  code: "cloud_setup_required",
  details: { family: "claude", model: "claude-opus-5-5" },
};

test("the host's refusal becomes Set up Cloud naming the model, never a failure line", () => {
  const ended = cloudStartEnded(begun, "k", refused);
  expect(ended?.cloudSetup).toEqual({ family: "claude", model: "claude-opus-5-5" });
  const html = renderToStaticMarkup(<CloudStartView start={ended!} onSetUp={() => undefined} />);
  expect(html).toContain(translate("cloudSetup.title"));
  expect(html).toContain(translate("cloudSetup.body"));
  expect(html).toContain(translate("cloudSetup.model", { model: "claude-opus-5-5" }));
  for (const label of ["cloudSetup.claude", "cloudSetup.chatgpt", "cloudSetup.apiKey", "cloudSetup.settings"] as const)
    expect(html).toContain(translate(label));
  // No checklist and no host words: nothing started.
  expect(html).not.toContain("acpmux-cloud-start__failure");
  expect(html).not.toContain("cloud_setup_required");
});

test("the family's own subscription leads", () => {
  expect(cloudSetupActions({ family: "claude" })[0]).toBe("setUpClaude");
  expect(cloudSetupActions({ family: "codex" })[0]).toBe("connectChatGPT");
  expect(readCloudSetupNeed({ family: "gemini" })).toBeUndefined();
  expect(readCloudSetupNeed({ family: "codex", model: "  " })).toEqual({ family: "codex" });
});

test("a button runs its way in for the start's key, and the start goes again once a connection serves", async () => {
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  let answer!: () => void;
  const call = (method: string, params?: Record<string, unknown>) => {
    calls.push({ method, ...(params ? { params } : {}) });
    return method === "cloud.setUp"
      ? new Promise<unknown>((resolve) => (answer = () => resolve({ ready: true })))
      : Promise.resolve();
  };
  const wait = waitForCloudSetUp(call, "k", "connectChatGPT", { family: "codex", model: "gpt-5.5" });
  expect(calls[0]).toEqual({ method: "cloud.setUp", params: { key: "k", action: "connectChatGPT", family: "codex" } });
  let again = 0;
  const started = startAfterSignIn(
    wait,
    () => true,
    () => {
      again += 1;
      return Promise.resolve({ ok: true });
    },
  );
  // Nothing goes until the host answers (a connection appeared).
  await Promise.resolve();
  expect(again).toBe(0);
  answer();
  expect(await started).toEqual({ ok: true });
  expect(again).toBe(1);
  // The card leaves its waiting state for the normal start.
  const waiting: CloudStartProgress = { ...begun, signingIn: true, cloudSetup: { family: "codex" } };
  expect(cloudStartSignedIn(waiting, "k")?.cloudSetup).toBeUndefined();
});

test("a set up past its limit shows the card again, naming the same model", async () => {
  const call = (method: string) =>
    method === "cloud.setUp" ? new Promise<unknown>(() => undefined) : Promise.resolve();
  const wait = waitForCloudSetUp(call, "k", "openSettings", { family: "claude", model: "claude-opus-5-5" }, 1);
  const end = await wait.ended;
  expect(end).not.toBe("signedIn");
  const ended = cloudStartEnded(begun, "k", end as Exclude<typeof end, "signedIn">);
  expect(ended?.cloudSetup).toEqual({ family: "claude", model: "claude-opus-5-5" });
});

test("a click on the card asks for that way in; while it waits the buttons rest", async () => {
  const mount = installDom();
  root = createRoot(mount);
  const picked: CloudSetupAction[] = [];
  const ended = cloudStartEnded(begun, "k", refused)!;
  await act(async () => root!.render(<CloudStartView start={ended} onSetUp={(action) => picked.push(action)} />));
  const button = (action: string) => mount.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!;
  await act(async () => button("setUpClaude").click());
  expect(picked).toEqual(["setUpClaude"]);
  await act(async () =>
    root!.render(<CloudStartView start={{ ...ended, state: "starting", signingIn: true }} onSetUp={() => undefined} />),
  );
  expect(mount.textContent).toContain(translate("cloudSetup.waiting"));
  expect(button("connectChatGPT").disabled).toBe(true);
});

test("the start carries the picker's effort and account", async () => {
  expect(cloudPickExtras({ effort: "high", route: "claude-login" })).toEqual({
    effort: "high",
    account: "claude-login",
  });
  expect(cloudPickExtras({ effort: "default", route: "a b" })).toEqual({});
  const sent: Record<string, unknown>[] = [];
  await startCloudChat(
    (_method, params) => {
      sent.push(params);
      return Promise.resolve();
    },
    { task: "t", home: true, harness: "claude", model: "claude-opus-5-5", effort: "high", account: "claude-login" },
    "k",
  );
  expect(sent[0]).toMatchObject({
    harness: "claude",
    model: "claude-opus-5-5",
    effort: "high",
    account: "claude-login",
  });
});

test("every gallery state renders", () => {
  for (const variant of Object.values(setupGallery.variants)) {
    const props = variant.props as Parameters<typeof CloudStartView>[0];
    expect(renderToStaticMarkup(<CloudStartView {...props} />)).toContain(translate("cloudSetup.title"));
  }
});
