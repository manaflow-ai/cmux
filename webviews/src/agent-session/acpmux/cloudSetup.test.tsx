// l10n-allow-file: test fixture prompts and model ids, not shipped UI.
// Cloud first use (cloudSetup.ts, conversation/CloudSetupCard.tsx): a start no connection serves shows
// Set up Cloud naming the model; a button runs its way in on this Mac, and the start goes again by
// itself once a connection serves the family.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { CloudStartView } from "./CloudStartView";
import {
  cloudStartBegun,
  cloudStartEnded,
  cloudStartSignedIn,
  heldCloudSetup,
  type CloudStartProgress,
} from "./cloudStartProgress";
import { cloudPickExtras, makeCloudSignInRetry, startCloudChat, type CloudStartAnswer } from "./cloudRun";
import {
  cloudSetupAction,
  connectHeldCloudSend,
  readCloudSetupNeed,
  retryWithSetUpPick,
  waitForCloudSetUp,
  type CloudSetupAction,
} from "./cloudSetup";
import { startAfterSignIn } from "./cloudSignIn";
import { translate } from "./i18n";
import setupGallery from "./CloudSetup.gallery";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, readonly [key: string, had: boolean, value: unknown]>();

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
    saved.set(key, [key, key in scope, scope[key]]);
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
  const window = dom?.window;
  dom = undefined;
  // React settles first, then each global this file added is removed (test/support/domTeardown.ts).
  await teardownDom(saved.values(), { ...(window ? { window } : {}), scope });
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
  expect(html).toContain(translate("cloudSetup.title", { name: "Claude" }));
  expect(html).toContain(translate("cloudSetup.body", { name: "Claude" }));
  expect(html).toContain(translate("cloudSetup.model", { model: "claude-opus-5-5" }));
  expect(html).toContain('data-action="setUpClaude"');
  expect(html.match(/data-role="default"/g)).toHaveLength(1);
  expect(html).not.toContain('data-action="addKey"');
  // No checklist and no host words: nothing started.
  expect(html).not.toContain("acpmux-cloud-start__failure");
  expect(html).not.toContain("cloud_setup_required");
});

test("each family has one setup action", () => {
  expect(cloudSetupAction({ family: "claude" })).toBe("setUpClaude");
  expect(cloudSetupAction({ family: "codex" })).toBe("addKey");
  expect(cloudSetupAction({ family: "codex" }, true)).toBe("connectChatGPT");
  expect(readCloudSetupNeed({ family: "codex", model: "  " })).toEqual({ family: "codex" });
});

test("the picker resumes the failed send on its selected machine", async () => {
  const ready = Promise.withResolvers<unknown>();
  const need = { family: "claude" };
  const attempts: unknown[] = [];
  const sent: string[] = [];
  const setup = (action: CloudSetupAction) => {
    const wait = waitForCloudSetUp(
      (method, params) => {
        attempts.push({ method, params });
        return ready.promise;
      },
      "held-send",
      action,
      need,
      undefined,
      "vm_b",
    );
    return startAfterSignIn(
      wait,
      () => true,
      async () => {
        sent.push("held prompt");
        return { ok: true };
      },
    );
  };
  let resumed: ReturnType<typeof setup> | undefined;
  expect(connectHeldCloudSend("codex", need, false, setup)).toBe(false);
  expect(
    connectHeldCloudSend("claude", need, false, (action) => {
      resumed = setup(action);
    }),
  ).toBe(true);
  const waiting = cloudStartBegun("held-send", "held prompt", undefined, undefined, true, true, need);
  expect(waiting.state).toBe("starting");
  expect(connectHeldCloudSend("claude", heldCloudSetup(waiting), waiting.signingIn === true, setup)).toBe(true);
  expect(heldCloudSetup(cloudStartSignedIn(waiting, "held-send"))).toBeUndefined();
  expect(attempts).toEqual([
    {
      method: "cloud.setUp",
      params: {
        key: "held-send",
        family: "claude",
        action: "setUpClaude",
        machine: "vm_b",
      },
    },
  ]);
  expect(sent).toEqual([]);
  ready.resolve({ ready: true });
  expect(await resumed).toEqual({ ok: true });
  expect(sent).toEqual(["held prompt"]);
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
  let expire!: () => void;
  const wait = waitForCloudSetUp(call, "k", "setUpClaude", { family: "claude", model: "claude-opus-5-5" }, (run) => {
    expire = run;
    return () => undefined;
  });
  expire();
  const end = await wait.ended;
  expect(end).not.toBe("signedIn");
  const ended = cloudStartEnded(begun, "k", end as Exclude<typeof end, "signedIn">);
  expect(ended?.cloudSetup).toEqual({ family: "claude", model: "claude-opus-5-5", timedOut: true });
  expect(renderToStaticMarkup(<CloudStartView start={ended!} />)).toContain("No connection yet.");
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
  expect(button("setUpClaude")).toBeNull();
  expect(button("run-here")).toBeNull();
});

test("a Set up Cloud press the resend did not take leaves no pick for a later Sign in", async () => {
  const slot: { current: CloudSetupAction | undefined } = { current: undefined };
  // What each resend found in the slot, as `beginCloudSend` reads it.
  const taken: (CloudSetupAction | undefined)[] = [];
  let answer!: (value: CloudStartAnswer) => void;
  let resend: () => Promise<CloudStartAnswer> | undefined = () => {
    taken.push(slot.current);
    return new Promise<CloudStartAnswer>((resolve) => (answer = resolve));
  };
  const retry = makeCloudSignInRetry(() => resend());
  // The first press resends with its way in.
  const first = retryWithSetUpPick(slot, "setUpClaude", retry);
  expect(taken).toEqual(["setUpClaude"]);
  expect(slot.current).toBeUndefined();
  // A second press while that resend is out sends nothing, and keeps nothing.
  void retryWithSetUpPick(slot, "addKey", retry);
  expect(taken).toEqual(["setUpClaude"]);
  expect(slot.current).toBeUndefined();
  answer({ ok: false, code: "cloud_setup_required" });
  expect(await first).toBe(false);
  // No start to resend (the chat or mode changed): the press keeps nothing either.
  resend = () => undefined;
  expect(await retryWithSetUpPick(slot, "openSettings", retry)).toBe(false);
  expect(slot.current).toBeUndefined();
  // The next plain Sign in finds no pick, so it signs in rather than setting up.
  resend = () => {
    taken.push(slot.current);
    return Promise.resolve({ ok: true });
  };
  expect(await retry()).toBe(true);
  expect(taken).toEqual(["setUpClaude", undefined]);
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
    expect(renderToStaticMarkup(<CloudStartView {...props} />)).toContain(
      translate("cloudSetup.title", { name: props.start.cloudSetup?.family === "codex" ? "Codex" : "Claude" }),
    );
  }
});

test("an unconnected provider chat points to its own settings", () => {
  for (const family of ["github-copilot", "openrouter", "gemini", "grok", "providers/custom"]) {
    const need = readCloudSetupNeed({ family });
    expect(need).toEqual({ family });
    expect(cloudSetupAction(need!)).toBe("openSettings");
  }
  expect(readCloudSetupNeed({ family: "providers//custom" })).toBeUndefined();
});
