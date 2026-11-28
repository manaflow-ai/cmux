// l10n-allow-file: test fixture prompts and model ids, not shipped UI.
// Cloud first use (cloudSetup.ts, conversation/CloudSetupCard.tsx): a start no connection serves shows
// Set up Cloud naming the model; a button runs its way in on this Mac, and the start goes again by
// itself once a connection serves the family.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { CloudStartView } from "./CloudStartView";
import { ClaudeConnectRow, useClaudeConnectFlow } from "./ClaudeConnectRow";
import {
  ClaudeConnectContext,
  checkToken,
  connectRequest,
  openClaudeCloudSettings,
  refusalText,
  setupConnect,
  type ClaudeConnect,
  type ConnectProgress,
} from "./claudeConnect";
import { ConnectCard } from "./ConnectCard";
import { normalizeClaudeToken } from "../shared/claudeSetupToken";
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
    "HTMLInputElement",
    "Event",
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
    HTMLInputElement: dom.window.HTMLInputElement,
    Event: dom.window.Event,
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
  expect(html).toContain(translate("cloudSetup.familyTitle", { name: "Claude" }));
  expect(html).toContain(translate("cloudSetup.body", { name: "Claude" }));
  expect(html).toContain(translate("cloudSetup.model", { model: "claude-opus-5-5" }));
  // The family's inline connect card leads: its mark, one line and one button; the rest stay quiet.
  expect(html).toContain('data-connect-card=""');
  expect(html).toContain(translate("connect.claude.line"));
  expect(html).toContain(translate("connect.claude.button"));
  expect(html).not.toContain('data-action="addKey"');
  expect(html).not.toContain('data-action="openSettings"');
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
      "env_0123456789abcdef01234567",
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
        environment: "env_0123456789abcdef01234567",
      },
    },
  ]);
  expect(sent).toEqual([]);
  ready.resolve({ ready: true });
  expect(await resumed).toEqual({ ok: true });
  expect(sent).toEqual(["held prompt"]);
});

test("an automatic send opens Settings on the planned machine, even when another VM is already signed in", async () => {
  const need = readCloudSetupNeed({ family: "claude", machine: "vm_with_space" });
  expect(need).toEqual({ family: "claude", machine: "vm_with_space" });
  const calls: unknown[] = [];
  const wait = waitForCloudSetUp(
    async (method, params) => {
      calls.push({ method, params });
      return { ready: true };
    },
    "held-send",
    "setUpClaude",
    need!,
  );
  expect(await wait.ended).toBe("signedIn");
  expect(calls).toEqual([
    {
      method: "cloud.setUp",
      params: { key: "held-send", family: "claude", action: "setUpClaude", machine: "vm_with_space" },
    },
  ]);
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

test("the connect card's one click asks for the family's way in; while it waits it shows progress and Cancel", async () => {
  const mount = installDom();
  root = createRoot(mount);
  const picked: CloudSetupAction[] = [];
  const ended = cloudStartEnded(begun, "k", refused)!;
  let local = 0;
  await act(async () =>
    root!.render(
      <CloudStartView start={ended} onSetUp={(action) => picked.push(action)} onRunHere={() => void local++} />,
    ),
  );
  await act(async () => mount.querySelector<HTMLButtonElement>('[data-action="run-here"]')!.click());
  expect(local).toBe(1);
  await act(async () => mount.querySelector<HTMLButtonElement>('[data-connect-action="begin"]')!.click());
  await act(async () => undefined);
  expect(picked).toEqual(["setUpClaude"]);
  let cancelled = 0;
  await act(async () =>
    root!.render(
      <CloudStartView
        start={{ ...ended, state: "starting", signingIn: true }}
        onSetUp={() => undefined}
        onRunHere={() => void local++}
        onSetUpDismiss={() => void cancelled++}
      />,
    ),
  );
  expect(mount.textContent).toContain(translate("connect.claude.signingIn"));
  expect(mount.querySelector('[data-connect-action="begin"]')).toBeNull();
  expect(mount.querySelector('[data-action="run-here"]')).toBeNull();
  expect(mount.querySelector('[data-action="dismiss"]')).toBeNull();
  await act(async () => mount.querySelector<HTMLButtonElement>('[data-connect-action="cancel"]')!.click());
  expect(cancelled).toBe(1);
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
      translate("cloudSetup.familyTitle", { name: props.start.cloudSetup?.family === "codex" ? "Codex" : "Claude" }),
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

async function mount(node: React.ReactNode): Promise<HTMLElement> {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(node));
  return container;
}

const field = (container: HTMLElement, name: string) =>
  container.querySelector<HTMLInputElement>(`input[name="${name}"]`)!;

async function typeInto(input: HTMLInputElement, value: string) {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, value);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

test("Claude setup tokens are normalized before shape validation and submission", () => {
  expect(checkToken("")).toBe("empty");
  expect(checkToken("   ")).toBe("empty");
  expect(checkToken(" sk-ant-oat01-abc ")).toBe("valid");
  expect(checkToken("sk-ant-api03-abc")).toBe("invalid");
  expect(checkToken("sk-ant-oat01-ab c")).toBe("valid");
  expect(checkToken("  sk-ant-oat01-ab\n   c-d_e\u200B \r\n")).toBe("valid");
  expect(normalizeClaudeToken(" sk-ant-oat01-ab\n\t c\uFEFF ")).toBe("sk-ant-oat01-abc");
  expect(connectRequest("sk-ant-oat01-ab\n  cd ", "")).toEqual({ token: "sk-ant-oat01-abcd" });
  // The shape is still checked: two digits and a dash after the prefix, then base64url only.
  expect(checkToken("sk-ant-oat01-")).toBe("invalid");
  expect(checkToken("sk-ant-oatxx-abc")).toBe("invalid");
  expect(checkToken("sk-ant-oat01-ab│cd")).toBe("invalid");
  expect(checkToken('"sk-ant-oat01-abc"')).toBe("invalid");
  expect(connectRequest(" sk-ant-oat01-abc ", "  ")).toEqual({ token: "sk-ant-oat01-abc" });
  expect(connectRequest("sk-ant-oat01-abc", " Work ")).toEqual({ token: "sk-ant-oat01-abc", label: "Work" });
  expect(refusalText(new Error(" Refused (401) "), "x")).toBe("Refused (401)");
  expect(refusalText("nope", "fallback")).toBe("fallback");
});

test("Connect opens the inline card already signing in; its progress line follows the host, then Connected", async () => {
  let begun = 0;
  let setProgress: (progress: ConnectProgress) => void = () => undefined;
  let setNeeded: (needed: boolean) => void = () => undefined;
  function Host() {
    const [needed, set] = useState(true);
    const [progress, put] = useState<ConnectProgress>({ phase: null, error: null });
    setNeeded = set;
    setProgress = put;
    const host: ClaudeConnect = {
      needed,
      progress,
      begin: async () => {
        begun++;
        put({ phase: "starting", error: null });
      },
      cancel: () => put({ phase: null, error: null }),
      add: async () => undefined,
    };
    return (
      <ClaudeConnectContext.Provider value={host}>
        <Picker />
      </ClaudeConnectContext.Provider>
    );
  }
  function Picker() {
    const { row, card } = useClaudeConnectFlow();
    return (
      <>
        {row && <ClaudeConnectRow name="Claude Code" connected={row.connected} onConnect={row.onConnect} />}
        {card}
      </>
    );
  }
  const doc = await mount(<Host />);
  const row = () => doc.querySelector<HTMLElement>(".acpmux-connect-claude-row");
  const card = () => doc.querySelector<HTMLElement>("[data-connect-card]");
  expect(row()?.textContent).toContain("Link your Claude subscription to use Claude Code");
  expect(card()).toBeNull();
  await act(async () => row()!.querySelector("button")!.click());
  expect(begun).toBe(1);
  expect(card()?.textContent).toContain("Opening the Claude sign-in page…");
  expect(card()?.querySelector('[data-connect-action="cancel"]')).not.toBeNull();
  await act(async () => setProgress({ phase: "signing_in", error: null }));
  expect(card()?.textContent).toContain("Waiting for you to sign in to Claude in the browser…");
  await act(async () => setProgress({ phase: "saving", error: null }));
  expect(card()?.textContent).toContain("Saving…");
  await act(async () => setProgress({ phase: null, error: null }));
  expect(card()?.textContent).toContain("Connected");
  expect(row()?.hasAttribute("data-connected")).toBe(true);
  await act(async () => setNeeded(false));
  expect(row()).toBeNull();
  expect(card()).toBeNull();
});

test("Cancel on the inline card is not a save: the row keeps Connect, never Connected", async () => {
  function Host() {
    const [progress, put] = useState<ConnectProgress>({ phase: null, error: null });
    const host: ClaudeConnect = {
      needed: true,
      progress,
      begin: async () => put({ phase: "signing_in", error: null }),
      cancel: () => put({ phase: null, error: null }),
    };
    return (
      <ClaudeConnectContext.Provider value={host}>
        <Picker />
      </ClaudeConnectContext.Provider>
    );
  }
  function Picker() {
    const { row, card } = useClaudeConnectFlow();
    return (
      <>
        {row && <ClaudeConnectRow name="Claude Code" connected={row.connected} onConnect={row.onConnect} />}
        {card}
      </>
    );
  }
  const doc = await mount(<Host />);
  const row = () => doc.querySelector<HTMLElement>(".acpmux-connect-claude-row");
  const card = () => doc.querySelector<HTMLElement>("[data-connect-card]");
  await act(async () => row()!.querySelector("button")!.click());
  await act(async () => card()!.querySelector<HTMLButtonElement>('[data-connect-action="cancel"]')!.click());
  expect(card()).toBeNull();
  expect(row()?.hasAttribute("data-connected")).toBe(false);
  expect(row()?.textContent).not.toContain("Connected");
});

test("the card shows the host's error with Try again, and Cancel withdraws a running sign-in", async () => {
  let begun = 0;
  let cancelled = 0;
  const render = (progress: ConnectProgress) => (
    <ConnectCard
      family="claude"
      progress={progress}
      onBegin={() => void begun++}
      onCancel={() => void cancelled++}
      onPaste={async () => undefined}
    />
  );
  const doc = await mount(render({ phase: null, error: "The sign-in page closed." }));
  const alert = doc.querySelector('[role="alert"]');
  expect(alert?.textContent).toBe("Couldn’t connect: The sign-in page closed.");
  const retry = doc.querySelector<HTMLButtonElement>('[data-connect-action="retry"]')!;
  expect(retry.textContent).toBe("Try again");
  await act(async () => retry.click());
  expect(begun).toBe(1);
  await act(async () => root!.render(render({ phase: "signing_in", error: null })));
  expect(doc.querySelector('[data-connect-action="retry"]')).toBeNull();
  expect(doc.querySelector("[data-connect-paste]")).toBeNull();
  await act(async () => doc.querySelector<HTMLButtonElement>('[data-connect-action="cancel"]')!.click());
  expect(cancelled).toBe(1);
});

test("Paste a token instead and Use an API key instead stay collapsed and send the value trimmed", async () => {
  const tokens: string[] = [];
  const keys: string[] = [];
  const doc = await mount(
    <ConnectCard
      family="claude"
      progress={{ phase: null, error: null }}
      onBegin={() => undefined}
      onPaste={async (token) => void tokens.push(token)}
      onApiKey={async (key) => void keys.push(key)}
    />,
  );
  const token = doc.querySelector<HTMLDetailsElement>('[data-connect-paste="token"]')!;
  const key = doc.querySelector<HTMLDetailsElement>('[data-connect-paste="key"]')!;
  expect(token.open).toBe(false);
  expect(key.open).toBe(false);
  expect(token.querySelector("summary")?.textContent).toBe("Paste a token instead");
  expect(key.querySelector("summary")?.textContent).toBe("Use an API key instead");
  await typeInto(field(doc, "token"), " sk-ant-oat01-\nabc ");
  await act(async () => token.querySelector("form")!.requestSubmit());
  await typeInto(field(doc, "key"), "  sk-ant-api03-xyz\n");
  await act(async () => key.querySelector("form")!.requestSubmit());
  expect(tokens).toEqual(["sk-ant-oat01-abc"]);
  expect(keys).toEqual(["sk-ant-api03-xyz"]);
});

test("without a host provider the picker gets no Connect row", async () => {
  let seen: unknown = "unset";
  function Picker() {
    seen = useClaudeConnectFlow().row;
    return null;
  }
  await mount(<Picker />);
  expect(seen).toBeUndefined();
});

test("the picker uses the held family's setup action and withdraws the original wait", async () => {
  const ran: CloudSetupAction[] = [];
  let cancelled = 0;
  const run = (action: CloudSetupAction) => void ran.push(action);
  expect(setupConnect(undefined, false, run)).toBeUndefined();
  expect(setupConnect({ family: "gemini" }, false, run)).toBeUndefined();
  const waiting = setupConnect({ family: "claude" }, true, run, () => void cancelled++)!;
  expect(waiting.progress).toEqual({ phase: "signing_in", error: null });
  await waiting.begin?.("claude");
  expect(ran).toEqual([]);
  waiting.cancel?.();
  expect(cancelled).toBe(1);
  const claude = setupConnect({ family: "claude" }, false, run)!;
  expect(claude.brands).toEqual(["claude"]);
  await claude.begin?.("claude");
  const codex = setupConnect({ family: "codex" }, false, run)!;
  expect(codex.brands).toEqual(["openai"]);
  expect(codex.begin).toBeUndefined();
  codex.open?.("openai");
  expect(ran).toEqual(["setUpClaude", "addKey"]);
});

test("Cloud Claude recovery opens Settings on the chat's machine", () => {
  const calls: unknown[] = [];
  const recover = openClaudeCloudSettings(async (method, params) => void calls.push({ method, params }), "vm_1");
  recover();
  expect(calls).toEqual([{ method: "cloud.connect", params: { family: "claude", machine: "vm_1" } }]);
});
