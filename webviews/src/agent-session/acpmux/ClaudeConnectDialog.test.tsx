// Connect your Claude subscription from the model picker (claudeConnect.ts): the token check shared
// with Settings > Models, focus in the token field, Return submits once, Escape cancels, the host's
// refusal shows, and a save closes the dialog and turns the picker row to Connected.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { isClaudeToken } from "../shared/claudeSetupToken";
import { isClaudeToken as settingsCheck } from "../../pages/settings/components/ModelsCard";
import {
  ClaudeConnectContext,
  checkToken,
  connectRequest,
  refusalText,
  setupConnect,
  type ClaudeConnect,
} from "./claudeConnect";
import type { CloudSetupAction } from "./cloudSetup";
import { ClaudeConnectDialog } from "./ClaudeConnectDialog";
import { ClaudeConnectRow, useClaudeConnectFlow } from "./ClaudeConnectRow";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

async function mount(node: React.ReactNode) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
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
  expect(checkToken("sk-ant-oat01 abc")).toBe("invalid");
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

test("Connect opens the dialog; a save closes it and the row says Connected until the host catches up", async () => {
  const added: unknown[][] = [];
  let setNeeded: (needed: boolean) => void = () => undefined;
  function Host() {
    const [needed, set] = useState(true);
    setNeeded = set;
    const host: ClaudeConnect = { needed, add: async (...args) => void added.push(args) };
    return (
      <ClaudeConnectContext.Provider value={host}>
        <Picker />
      </ClaudeConnectContext.Provider>
    );
  }
  function Picker() {
    const { row, dialog } = useClaudeConnectFlow();
    return (
      <>
        {row && <ClaudeConnectRow name="Claude Code" connected={row.connected} onConnect={row.onConnect} />}
        {dialog}
      </>
    );
  }
  const doc = await mount(<Host />);
  const row = () => doc.querySelector<HTMLElement>(".acpmux-connect-claude-row");
  expect(row()?.textContent).toContain("Link your Claude subscription to use Claude Code");
  await act(async () => row()!.querySelector("button")!.click());
  await nextFrame();
  expect(dialogOf(doc)).not.toBeNull();
  await typeInto(field(doc, "token"), "sk-ant-oat01-abc");
  await submit(doc);
  expect(added).toEqual([["sk-ant-oat01-abc", undefined]]);
  await nextFrame();
  expect(dialogOf(doc)).toBeNull();
  expect(row()?.hasAttribute("data-connected")).toBe(true);
  expect(row()?.textContent).toContain("Connected");
  expect(row()?.querySelector("button")).toBeNull();
  await act(async () => setNeeded(false));
  expect(row()).toBeNull();
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

test("the chat's Set up Cloud need gives the Connect row for its family; no need, or a wait out, gives none", () => {
  const ran: CloudSetupAction[] = [];
  const run = (action: CloudSetupAction) => void ran.push(action);
  expect(setupConnect(undefined, false, run)).toBeUndefined();
  expect(setupConnect({ family: "claude" }, true, run)).toBeUndefined();
  const claude = setupConnect({ family: "claude", model: "opus" }, false, run)!;
  expect(claude).toMatchObject({ needed: true, brand: "claude" });
  expect(claude.add).toBeUndefined();
  claude.open!();
  const codex = setupConnect({ family: "codex" }, false, run)!;
  expect(codex).toMatchObject({ needed: true, brand: "openai" });
  codex.open!();
  expect(ran).toEqual(["setUpClaude", "connectChatGPT"]);
});

test("a host with its own way in takes Connect there, with no dialog; Codex's row reads its ChatGPT way in", async () => {
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
    const { row, dialog } = useClaudeConnectFlow();
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
        {dialog}
      </>
    );
  }
  const doc = await mount(<Host />);
  const row = () => doc.querySelector<HTMLElement>(".acpmux-connect-claude-row");
  expect(brand).toBe("openai");
  expect(row()?.textContent).toContain("Continue with ChatGPT");
  await act(async () => row()!.querySelector("button")!.click());
  await nextFrame();
  expect(dialogOf(doc)).toBeNull();
  family = "claude";
  await act(async () => rerender());
  expect(row()?.textContent).toContain("Link your Claude subscription to use Claude Code");
  await act(async () => row()!.querySelector("button")!.click());
  await nextFrame();
  expect(dialogOf(doc)).toBeNull();
  expect(ran).toEqual(["connectChatGPT", "setUpClaude"]);
});
