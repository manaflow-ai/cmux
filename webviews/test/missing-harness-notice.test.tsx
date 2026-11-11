// Leo 2026-11-11: a friend "tried to start a chat, didn't have Claude or Codex installed, ran into"
// setup text, "and then there was no recovery mechanism". A chat whose agent is not on this Mac
// shows one line with Install (and Use Codex Instead when Codex is here); Install runs the
// installer in place, signs in when it must, then sends the message the person typed. The notice,
// its hook and the shared in-place install (harnessSetup.ts), in JSDOM, over a fake app host.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MouseEvent",
  "Event",
  "getComputedStyle",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  (await import("../src/agent-session/acpmux/harnessSetup")).resetHarnessSetupForTests();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type PickerCatalog = import("../src/agent-session/acpmux/modelCatalogData").PickerCatalog;
type Call = { method: string; params: Record<string, unknown> };

/// acpmux refused `session/new` for Claude Code (harness_install.rs `NOT_INSTALLED`); the switch
/// failed with its code, and the typed message is back in the composer.
const refused: Snapshot["switching"] = {
  harness: "claude",
  name: "Claude Code",
  phase: "failed",
  error: "Claude Code is not installed on this machine",
  code: "harness.not_installed",
};

function catalog(codex: boolean): PickerCatalog {
  const entry = (id: string, name: string, installed: boolean, family?: string) => ({
    id,
    name,
    brand: id,
    acpmuxHarness: installed ? id : null,
    installed,
    pickable: true,
    ...(family ? { family } : {}),
    defaultModel: `${id}-default`,
    models: [],
  });
  return {
    provisional: false,
    harnesses: [
      entry("claude", "Claude Code", false),
      entry("codex", "Codex", codex),
      // The built-in agents are never the alternative.
      entry("chief", "Chief", true, "chief"),
      entry("unii", "UniiChat", true, "unii"),
    ],
  };
}

type Host = {
  calls: Call[];
  sent: number;
  retried: number;
  rows: string[][];
  edited: string[][];
  logIns: string[];
  /// What `harness.health` answers after the install, in order (the last repeats).
  health: Array<{ auth: string; login?: string }>;
  /// The installer's exit code.
  exit: number;
  /// The installer runs until this settles.
  gate?: Promise<void>;
};

function fakeHost(over: Partial<Host> = {}): Host {
  return {
    calls: [],
    sent: 0,
    retried: 0,
    rows: [],
    edited: [],
    logIns: [],
    health: [{ auth: "signedIn" }],
    exit: 0,
    ...over,
  };
}

async function render(
  fake: Host,
  props: { switching?: Snapshot["switching"]; failedRows?: string[]; codex?: boolean } = {},
) {
  const { MissingHarnessNotice } = await import("../src/agent-session/acpmux/MissingHarnessNotice");
  const { useMissingHarness } = await import("../src/agent-session/acpmux/missingHarness");
  const { createRoot } = await import("react-dom/client");
  const native = async (method: string, params: Record<string, unknown> = {}) => {
    fake.calls.push({ method, params });
    if (method === "shell.run") return { id: "run-1" };
    if (method === "shell.read") {
      await fake.gate;
      return {
        output: fake.exit === 0 ? "Claude Code installed\n" : "curl: (6) Could not resolve host: claude.ai\n",
        next: 1,
        exit: { code: fake.exit },
      };
    }
    if (method === "harness.health") {
      const answer = fake.health.length > 1 ? fake.health.shift()! : fake.health[0]!;
      return { health: { id: "claude", ...answer } };
    }
    if (method === "chat.new") return "session-1";
    return undefined;
  };
  function Pane() {
    const notice = useMissingHarness({
      switching: props.switching,
      failedRows: props.failedRows ?? [],
      composerHarness: { harness: "claude", name: "Claude Code" },
      local: true,
      catalog: catalog(props.codex ?? false),
      native,
      cwd: "/Users/you/src/app",
      logIn: async (_harness, login) => {
        fake.logIns.push(login);
        return true;
      },
      retry: async () => {
        fake.retried += 1;
      },
      send: () => {
        fake.sent += 1;
      },
      retryRows: (rowIds) => fake.rows.push([...rowIds]),
      editRows: (rowIds) => fake.edited.push([...rowIds]),
      setUp: () => undefined,
      pollMs: 5,
    });
    return notice ? <MissingHarnessNotice {...notice} /> : null;
  }
  await act(async () => {
    root = createRoot(host);
    root.render(<Pane />);
  });
}

const notice = () => host.querySelector<HTMLElement>("[data-missing-harness]");
const button = (action: string) => host.querySelector<HTMLButtonElement>(`[data-missing-action="${action}"]`);
const buttons = () => [...host.querySelectorAll<HTMLButtonElement>("button")].map((b) => b.textContent);

async function click(action: string) {
  const target = button(action);
  if (!target) throw new Error(`no ${action} button: ${host.innerHTML}`);
  await act(async () => {
    target.click();
  });
}

/// Yields to the next macrotask until `check` holds: a condition, never a fixed time.
async function until(check: () => boolean, what: string) {
  for (let i = 0; i < 20_000; i += 1) {
    if (check()) return;
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
  throw new Error(`timed out waiting for ${what}: ${host.innerHTML}`);
}

test("a failed start names the missing agent with Install, and Use Codex Instead only when Codex is here", async () => {
  await render(fakeHost(), { switching: refused });
  expect(notice()?.getAttribute("data-missing-harness")).toBe("missing");
  expect(host.querySelector(".acpmux-host-error-message")?.textContent).toBe("Claude Code isn't installed.");
  // One way out, no command text, no paragraph.
  expect(buttons()).toEqual(["Install Claude Code"]);
  expect(host.textContent).not.toContain("curl");
  act(() => root?.unmount());

  const fake = fakeHost();
  await render(fake, { switching: refused, codex: true });
  expect(buttons()).toEqual(["Install Claude Code", "Use Codex Instead"]);
  await click("instead");
  expect(fake.calls.find((call) => call.method === "chat.new")?.params).toEqual({
    harness: "codex",
    cwd: "/Users/you/src/app",
  });
  await until(() => fake.sent === 1, "the typed message to go to Codex");
  expect(fake.calls.some((call) => call.method === "shell.run")).toBe(false);
});

test("Install runs the installer in place, says so, then starts the chat and sends the typed message", async () => {
  const { INSTALL_COMMANDS } = await import("../src/agent-session/acpmux/harnesses/harnessRows");
  // The installer never ends until the test lets it: the in-progress state shows.
  let finish: () => void = () => undefined;
  const fake = fakeHost({ gate: new Promise<void>((resolve) => (finish = resolve)) });
  await render(fake, { switching: refused });
  await click("install");
  expect(notice()?.getAttribute("data-missing-harness")).toBe("installing");
  expect(host.querySelector(".acpmux-host-error-message")?.textContent).toBe("Installing Claude Code…");
  // No buttons while it runs.
  expect(buttons()).toEqual([]);
  finish();
  await until(() => fake.sent === 1, "the typed message to go");
  expect(fake.calls.find((call) => call.method === "shell.run")?.params).toEqual({
    command: INSTALL_COMMANDS.claude,
    cwd: "/Users/you/src/app",
  });
  // acpmux looked for the new CLI, the failed start ran again, then the message went: in that order.
  expect(fake.calls.some((call) => call.method === "harness.health" && call.params.rescan === true)).toBe(true);
  expect(fake.retried).toBe(1);
  expect(fake.logIns).toEqual([]);
});

test("a fresh install that is signed out asks for its sign-in, then sends the typed message", async () => {
  const fake = fakeHost({
    health: [{ auth: "signedOut", login: "claude auth login" }, { auth: "signedOut" }, { auth: "signedIn" }],
  });
  await render(fake, { switching: refused });
  await click("install");
  await until(() => notice()?.getAttribute("data-missing-harness") === "signIn", "the sign-in step");
  expect(host.querySelector(".acpmux-host-error-message")?.textContent).toBe(
    "Sign in to Claude Code to start the chat.",
  );
  expect(buttons()).toEqual(["Sign In"]);
  // Nothing went before the sign-in.
  expect(fake.sent).toBe(0);
  await click("signIn");
  expect(fake.logIns).toEqual(["claude auth login"]);
  await until(() => fake.sent === 1, "the typed message after the sign-in");
  expect(fake.retried).toBe(1);
});

test("a failed install says so in one line with Try Again; the installer's words wait under Details", async () => {
  const fake = fakeHost({ exit: 1 });
  await render(fake, { switching: refused, codex: true });
  await click("install");
  await until(() => notice()?.getAttribute("data-missing-harness") === "failed", "the failure");
  expect(host.querySelector(".acpmux-host-error-message")?.textContent).toBe("Couldn’t set up Claude Code");
  expect(button("install")?.textContent).toBe("Try Again");
  expect(button("instead")?.textContent).toBe("Use Codex Instead");
  expect(fake.sent).toBe(0);
});

test("a send refused with no agent named offers Install, then sends the refused prompts again", async () => {
  const fake = fakeHost();
  await render(fake, { failedRows: ["local-1"] });
  expect(buttons()).toEqual(["Install Claude Code"]);
  await click("install");
  await until(() => fake.rows.length === 1, "the refused prompt to go again");
  expect(fake.rows).toEqual([["local-1"]]);
  // A refused prompt is a row, not the composer's text: no start retried, no composer send.
  expect(fake.retried).toBe(0);
  expect(fake.sent).toBe(0);
});

test("another start failure shows no install notice", async () => {
  await render(fakeHost(), {
    switching: { harness: "claude", name: "Claude Code", phase: "failed", error: "connect ECONNREFUSED 127.0.0.1" },
  });
  expect(notice()).toBeNull();
});

test("the start's own words still say not installed for an older acpmux with no code", async () => {
  const { startNotInstalled } = await import("../src/agent-session/acpmux/startFailure");
  expect(
    startNotInstalled({ harness: "claude", name: "Claude Code", error: "failed to spawn agent: spawn claude ENOENT" }),
  ).toBe(true);
  expect(startNotInstalled(refused!)).toBe(true);
});
