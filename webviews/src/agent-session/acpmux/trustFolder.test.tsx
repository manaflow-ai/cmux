import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { TrustFolderDialog } = await import("./TrustFolderDialog");
const { needsTrust, readTrust, stricterTrust } = await import("./folderTrust");
const { MockAcpmuxSocket } = await import("./mock");
const { promptField, typeInto } = await import("./promptFieldTesting");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const key = (target: Element, name: string) =>
  act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });

test("a trust reply reads as its folder and level; only an unknown folder asks, and a host that can't say never blocks", async () => {
  expect(readTrust({ cwd: "/a", level: "trusted" })).toEqual({ cwd: "/a", level: "trusted" });
  expect(
    readTrust({ cwd: "/a", level: "unknown", harnesses: { claude: "unknown", codex: "trusted", other: "x" } }),
  ).toEqual({ cwd: "/a", level: "unknown", harnesses: { claude: "unknown", codex: "trusted" } });
  expect(stricterTrust("trusted", "unknown")).toBe("unknown");
  expect(stricterTrust("unknown", "untrusted")).toBe("untrusted");
  expect(stricterTrust("trusted", "trusted")).toBe("trusted");
  expect(readTrust({ cwd: "/a", level: "maybe" })).toBeUndefined();
  expect(readTrust(null)).toBeUndefined();
  const source = (level: unknown) => ({ get: async (cwd: string) => ({ cwd, level }), set: async () => ({}) });
  expect(await needsTrust(source("unknown"), "/a")).toBe(true);
  expect(await needsTrust(source("trusted"), "/a")).toBe(false);
  expect(await needsTrust(source("untrusted"), "/a")).toBe(false);
  expect(await needsTrust(source("unknown"), undefined)).toBe(false);
  expect(
    await needsTrust({ get: () => Promise.reject(new Error("no such method")), set: async () => ({}) }, "/a"),
  ).toBe(false);
  expect(await needsTrust({ get: async () => ({}), set: async () => ({}) }, "/a")).toBe(false);
  // A host that never answers lets the send go once the wait runs out.
  expect(await needsTrust({ get: () => new Promise(() => {}), set: async () => ({}) }, "/a", 10)).toBe(false);
});

const snapshot = (): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
});

test("a send waits on confirmSend: no keeps the prompt, yes sends it once, and a failure sends it", async () => {
  const sent: string[] = [];
  let answer: ((go: boolean) => void) | undefined;
  let fail: ((error: Error) => void) | undefined;
  let asked = 0;
  await act(async () =>
    root.render(
      createElement(Composer, {
        snapshot: snapshot(),
        chips: () => null,
        onSend: (text: string) => sent.push(text),
        onStop: () => {},
        confirmSend: () => {
          asked++;
          return new Promise<boolean>((resolve, reject) => {
            answer = resolve;
            fail = reject;
          });
        },
      }),
    ),
  );
  // Milkdown makes its editor a task after the composer mounts.
  await settle();
  const prompt = promptField(doc);
  await act(async () => typeInto(prompt, "Fix the build"));
  await key(prompt.element, "Enter");
  // A second Enter while the first waits asks nothing more.
  await key(prompt.element, "Enter");
  expect(asked).toBe(1);
  expect(sent).toEqual([]);
  await act(async () => answer!(false));
  expect(sent).toEqual([]);
  expect(prompt.value).toBe("Fix the build");
  await key(prompt.element, "Enter");
  // The dialog took focus; sending from Enter hands it back to the prompt.
  (doc.activeElement as HTMLElement | null)?.blur();
  await act(async () => answer!(true));
  expect(sent).toEqual(["Fix the build"]);
  expect(prompt.value).toBe("");
  expect(doc.activeElement).toBe(prompt.element);
  await act(async () => typeInto(prompt, "Then the tests"));
  await key(prompt.element, "Enter");
  await act(async () => fail!(new Error("host gone")));
  await settle();
  expect(sent).toEqual(["Fix the build", "Then the tests"]);
});

test("the dialog names the folder and the agent, focuses Trust folder, and Escape, Close or Cancel back out", async () => {
  let trusted = 0;
  let cancelled = 0;
  let saving: { resolve(): void; reject(error: Error): void } | undefined;
  await act(async () =>
    root.render(
      createElement(
        "section",
        null,
        createElement("main", { id: "pane" }, createElement("textarea")),
        createElement(TrustFolderDialog, {
          cwd: "/Users/me/code/billing-service",
          agent: "Claude Code",
          onTrust: () => {
            trusted++;
            return new Promise<void>((resolve, reject) => {
              saving = { resolve, reject };
            });
          },
          onCancel: () => cancelled++,
        }),
      ),
    ),
  );
  // Modal: the rest of the pane is inert while it asks.
  expect(doc.getElementById("pane")!.hasAttribute("inert")).toBe(true);
  const dialog = doc.querySelector("dialog.acpmux-trust")!;
  expect(doc.getElementById(dialog.getAttribute("aria-labelledby")!)!.textContent).toBe("Trust this folder?");
  expect(dialog.querySelector(".acpmux-trust-path")!.textContent).toBe("/Users/me/code/billing-service");
  expect(doc.getElementById(dialog.getAttribute("aria-describedby")!)!.textContent).toStartWith(
    "Claude Code can read, edit, and execute files here.",
  );
  const trust = dialog.querySelector<HTMLButtonElement>(".acpmux-trust-primary")!;
  expect(doc.activeElement).toBe(trust);
  await act(async () => trust.click());
  // A second click while saving records nothing twice.
  await act(async () => trust.click());
  expect(trusted).toBe(1);
  expect(trust.getAttribute("aria-busy")).toBe("true");
  await act(async () => saving!.reject(new Error("read-only config")));
  expect(dialog.querySelector("[role=alert]")!.textContent).toBe("Couldn't save that. Try again.");
  await act(async () => trust.click());
  await act(async () => saving!.resolve());
  expect(dialog.querySelector("[role=alert]")).toBeNull();
  await key(trust, "Escape");
  await act(async () => dialog.querySelector<HTMLButtonElement>(".acpmux-trust-close")!.click());
  await act(async () => dialog.querySelector<HTMLButtonElement>(".acpmux-trust-secondary")!.click());
  expect(cancelled).toBe(3);
  await act(async () => root.render(createElement("section", null, createElement("main", { id: "pane" }))));
  expect(doc.getElementById("pane")!.hasAttribute("inert")).toBe(false);
});

test("closing hands focus back to what had it before the dialog, once the pane is no longer inert", async () => {
  const shell = (asking: boolean) =>
    createElement(
      "section",
      null,
      createElement("main", { id: "pane" }, createElement("textarea", { id: "prompt" })),
      asking &&
        createElement(TrustFolderDialog, {
          cwd: "/a",
          agent: "Codex",
          onTrust: async () => {},
          onCancel: () => {},
        }),
    );
  await act(async () => root.render(shell(false)));
  const prompt = doc.getElementById("prompt")!;
  prompt.focus();
  await act(async () => root.render(shell(true)));
  expect(doc.activeElement).not.toBe(prompt);
  // The answer's own refocus ran while the pane was inert and did nothing; focus sits on the page.
  (doc.activeElement as HTMLElement).blur();
  await act(async () => root.render(shell(false)));
  expect(doc.getElementById("pane")!.hasAttribute("inert")).toBe(false);
  expect(doc.activeElement).toBe(prompt);
});

test("the mock daemon projects both agents' levels read-only, and set writes only acpmux's own record", async () => {
  const socket = new MockAcpmuxSocket();
  const answer = (
    socket as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> }
  ).answer.bind(socket);
  expect(await answer("acp.trust.get", { cwd: "~/code/cmux" })).toEqual({
    cwd: "~/code/cmux",
    level: "trusted",
    harnesses: { claude: "trusted", codex: "trusted" },
  });
  // atlas-web: Claude Code never decided, so the projection is unknown, but acpmux's record says trusted.
  expect(await answer("acp.trust.get", { cwd: "~/code/atlas-web" })).toEqual({
    cwd: "~/code/atlas-web",
    level: "trusted",
    harnesses: { claude: "unknown", codex: "trusted" },
  });
  expect(await answer("acp.trust.get", { cwd: "~/code/billing-service" })).toEqual({
    cwd: "~/code/billing-service",
    level: "unknown",
    harnesses: { claude: "unknown", codex: "unknown" },
  });
  expect(await answer("acp.trust.set", { cwd: "~/code/billing-service", level: "trusted" })).toEqual({
    cwd: "~/code/billing-service",
    level: "trusted",
  });
  // The decision is acpmux's; the agents' own levels read the same as before.
  expect(await answer("acp.trust.get", { cwd: "~/code/billing-service" })).toEqual({
    cwd: "~/code/billing-service",
    level: "trusted",
    harnesses: { claude: "unknown", codex: "unknown" },
  });
  socket.close();
});
