// Connect your Claude subscription from the model picker (claudeConnect.ts): the token check shared
// with Settings > Models; the paste dialog (kept for hosts that only take a token) focuses its field,
// submits once and cancels on Escape; the picker's Connect opens the inline connect card
// (ConnectCard.tsx), starts the one click and follows its progress line to Connected.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { isClaudeToken, normalizeClaudeToken } from "../shared/claudeSetupToken";
import { isClaudeToken as settingsCheck } from "../../pages/settings/components/ModelsCard";
import {
  ClaudeConnectContext,
  checkToken,
  connectRequest,
  refusalText,
  setupConnect,
  type ClaudeConnect,
  type ConnectProgress,
} from "./claudeConnect";
import type { CloudSetupAction } from "./cloudSetup";
import { ClaudeConnectDialog } from "./ClaudeConnectDialog";
import { ClaudeConnectRow, useClaudeConnectFlow } from "./ClaudeConnectRow";
import { ConnectCard } from "./ConnectCard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, readonly [key: string, had: boolean, value: unknown]>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Event",
  "KeyboardEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  const window = dom?.window;
  dom = undefined;
  // React settles first, then each global this file added is removed (test/support/leakDetector.ts).
  await teardownDom(saved.values(), { ...(window ? { window } : {}), scope });
  saved.clear();
});

async function mount(node: React.ReactNode) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, [key, key in scope, scope[key]]);
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Event: dom.window.Event,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: w.requestAnimationFrame,
    cancelAnimationFrame: w.cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root!.render(node));
  // Base UI moves the initial focus after a frame.
  await nextFrame();
  return dom.window.document;
}

/// One painted frame (Base UI opens, focuses and closes the dialog on the frame after a change).
const nextFrame = () =>
  act(async () => {
    await new Promise<void>((resolve) => dom!.window.requestAnimationFrame(() => resolve()));
    await new Promise<void>((resolve) => dom!.window.requestAnimationFrame(() => resolve()));
  });

const dialogOf = (doc: Document) => doc.querySelector<HTMLElement>(".acpmux-connect-claude");
const field = (doc: Document, name: string) => doc.querySelector<HTMLInputElement>(`input[name="${name}"]`)!;
const primary = (doc: Document) => doc.querySelector<HTMLButtonElement>('button[type="submit"]')!;

async function typeInto(input: HTMLInputElement, value: string) {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, value);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

const submit = (doc: Document) =>
  act(async () => {
    doc.querySelector("form")!.dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
  });

test("the token check is the one Settings > Models uses", () => {
  expect(settingsCheck).toBe(isClaudeToken);
  expect(checkToken("")).toBe("empty");
  expect(checkToken("   ")).toBe("empty");
  expect(checkToken(" sk-ant-oat01-abc ")).toBe("valid");
  expect(checkToken("sk-ant-api03-abc")).toBe("invalid");
  // Leo, 2026-11-25: "your terminal sometimes gets cut off with spaces and the text entry doesnt strip
  // spaces". Whitespace anywhere, a wrapped line or a zero-width space is taken out, not refused.
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

test("rest: the steps, the command with its copy button, focus in the token field, submit off", async () => {
  const doc = await mount(
    <ClaudeConnectDialog add={async () => undefined} onClose={() => undefined} onConnected={() => undefined} />,
  );
  const dialog = dialogOf(doc)!;
  expect(dialog.querySelector("h2")?.textContent).toBe("Connect your Claude subscription");
  expect(dialog.querySelector("code")?.textContent).toBe("claude setup-token");
  expect(dialog.querySelector('button[aria-label="Copy command"]')).not.toBeNull();
  expect(field(doc, "token").placeholder).toBe("sk-ant-oat01-…");
  expect(field(doc, "label").placeholder).toBe("Account email or name");
  expect(dialog.textContent).toContain("cmux checks the token before saving it");
  expect(dialog.textContent).toContain("Optional, otherwise shown as Claude subscription");
  expect(doc.activeElement).toBe(field(doc, "token"));
  expect(primary(doc).disabled).toBe(true);
  expect(primary(doc).textContent).toContain("Verify and connect");
});

test("a value that is not a setup token shows the inline error and keeps submit off", async () => {
  const sent: unknown[] = [];
  const doc = await mount(
    <ClaudeConnectDialog
      add={async (...args) => void sent.push(args)}
      onClose={() => undefined}
      onConnected={() => undefined}
    />,
  );
  await typeInto(field(doc, "token"), "sk-ant-api03-key");
  expect(doc.querySelector('[role="alert"]')?.textContent).toContain("isn’t a Claude setup token");
  expect(field(doc, "token").getAttribute("aria-invalid")).toBe("true");
  expect(primary(doc).disabled).toBe(true);
  await submit(doc);
  expect(sent).toEqual([]);
});

test("Return submits once, the button says Verifying… while it runs, and a refusal shows the reason", async () => {
  const sent: unknown[][] = [];
  let refuse: (error: Error) => void = () => undefined;
  const doc = await mount(
    <ClaudeConnectDialog
      add={(...args) => {
        sent.push(args);
        return new Promise<void>((_, reject) => (refuse = reject));
      }}
      onClose={() => undefined}
      onConnected={() => undefined}
    />,
  );
  await typeInto(field(doc, "token"), "sk-ant-oat01-secret0123");
  await typeInto(field(doc, "label"), "Work");
  expect(primary(doc).disabled).toBe(false);
  await submit(doc);
  await submit(doc);
  expect(sent).toEqual([["sk-ant-oat01-secret0123", "Work"]]);
  expect(primary(doc).textContent).toContain("Verifying…");
  expect(doc.querySelector("form")?.getAttribute("aria-busy")).toBe("true");
  expect(field(doc, "token").disabled).toBe(true);
  // The token leaves the form's state once it is sent.
  expect(field(doc, "token").value).toBe("");
  expect(doc.body.innerHTML).not.toContain("secret0123");
  await act(async () => refuse(new Error("Claude refused this token (401)")));
  expect(doc.querySelector("[data-connect-refused]")?.textContent).toBe(
    "Couldn’t connect: Claude refused this token (401)",
  );
  expect(primary(doc).textContent).toContain("Verify and connect");
  expect(field(doc, "token").disabled).toBe(false);
});

test("Escape cancels", async () => {
  let closed = 0;
  const doc = await mount(
    <ClaudeConnectDialog add={async () => undefined} onClose={() => closed++} onConnected={() => undefined} />,
  );
  await act(async () => {
    field(doc, "token").dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(closed).toBe(1);
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
  await nextFrame();
  expect(begun).toBe(1);
  expect(dialogOf(doc)).toBeNull();
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
  await nextFrame();
  await act(async () => card()!.querySelector<HTMLButtonElement>('[data-connect-action="cancel"]')!.click());
  await nextFrame();
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
  await nextFrame();
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

test("the chat's Set up Cloud need gives the one click for its family; while it waits, progress and Cancel", async () => {
  const ran: CloudSetupAction[] = [];
  let cancelled = 0;
  const run = (action: CloudSetupAction) => void ran.push(action);
  expect(setupConnect(undefined, false, run)).toBeUndefined();
  const waiting = setupConnect({ family: "claude" }, true, run, () => void cancelled++)!;
  expect(waiting.progress).toEqual({ phase: "signing_in", error: null });
  waiting.cancel!();
  expect(cancelled).toBe(1);
  const claude = setupConnect({ family: "claude", model: "opus" }, false, run)!;
  expect(claude).toMatchObject({ needed: true, brand: "claude", progress: { phase: null, error: null } });
  expect(claude.add).toBeUndefined();
  await claude.begin!();
  const codex = setupConnect({ family: "codex" }, false, run)!;
  expect(codex).toMatchObject({ needed: true, brand: "openai" });
  await codex.begin!();
  expect(ran).toEqual(["setUpClaude", "connectChatGPT"]);
});

test("a Cloud need's Connect starts the family's one click in the inline card; Codex's card says ChatGPT", async () => {
  const ran: CloudSetupAction[] = [];
  let family: "claude" | "codex" = "codex";
  let rerender: () => void = () => undefined;
  function Host() {
    const [, bump] = useState(0);
    rerender = () => bump((n) => n + 1);
    return (
      <ClaudeConnectContext.Provider value={setupConnect({ family }, false, (action) => void ran.push(action))}>
        <Picker />
      </ClaudeConnectContext.Provider>
    );
  }
  let brand: string | undefined;
  function Picker() {
    const { row, card } = useClaudeConnectFlow();
    brand = row?.brand;
    return (
      <>
        {row && (
          <ClaudeConnectRow
            name={row.brand === "openai" ? "Codex" : "Claude Code"}
            mark={row.brand === "openai" ? "codex" : "claude"}
            connected={row.connected}
            onConnect={row.onConnect}
          />
        )}
        {card}
      </>
    );
  }
  const doc = await mount(<Host />);
  const row = () => doc.querySelector<HTMLElement>(".acpmux-connect-claude-row");
  const card = () => doc.querySelector<HTMLElement>("[data-connect-card]");
  expect(brand).toBe("openai");
  expect(row()?.textContent).toContain("Continue with ChatGPT");
  await act(async () => row()!.querySelector("button")!.click());
  await nextFrame();
  expect(dialogOf(doc)).toBeNull();
  expect(card()?.getAttribute("data-family")).toBe("codex");
  expect(card()?.textContent).toContain("Connect your ChatGPT plan to run Codex in Cloud");
  family = "claude";
  await act(async () => rerender());
  expect(card()?.getAttribute("data-family")).toBe("claude");
  await act(async () => card()!.querySelector<HTMLButtonElement>('[data-connect-action="begin"]')!.click());
  await nextFrame();
  expect(ran).toEqual(["connectChatGPT", "setUpClaude"]);
});
