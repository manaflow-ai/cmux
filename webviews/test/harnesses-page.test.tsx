// Integrate a harness (cx-uj5g8): the Harnesses page lists the agent CLIs cmux knows, in place in
// the pane, each with its state on this Mac (ready, signed out, not installed) and one action:
// Start Chat, Sign In (the CLI's login in a terminal tab) or Install… (its setup page). Custom
// harness… starts the `cmux harness guide` chat in this tab, in the chat's folder. The New Tab
// tools row no longer carries Integrate a harness.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HarnessesScreen } from "../src/agent-session/acpmux/harnesses/HarnessesScreen";
import { INSTALL_COMMANDS } from "../src/agent-session/acpmux/harnesses/harnessRows";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "../src/agent-session/acpmux/modelCatalogData";
import { NewTabScreen } from "../src/agent-session/acpmux/newtab/NewTabScreen";
import type { HarnessHealth } from "../src/agent-session/acpmux/HarnessHealthNotice";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { noChat } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
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

type Call = { method: string; params: Record<string, unknown> };

// This Mac: Claude Code signed in, Codex signed out, Grok (no catalog entry) ready; OpenCode, Pi
// and Vercel AI Gateway are not installed.
const acpmux: AcpmuxSnapshot["catalog"] = [
  { id: "claude", name: "Claude Code", family: "claude", models: [] },
  { id: "codex", name: "Codex", family: "codex", models: [], auth: { login: "codex login" } },
  { id: "grok", name: "Grok", family: "grok", models: [] },
];

type Page = {
  calls?: Call[];
  closed?: string[];
  acpmux?: AcpmuxSnapshot["catalog"];
  /// What the install command prints, and its exit code.
  /// `ends` holds the last reply; `endsWithOutput`: that reply is more output, not the exit.
  shell?: { output: string[]; code: number; ends?: Promise<void>; endsWithOutput?: boolean };
  /// The sign-in check's answer for each harness (default: Codex signed out, the rest signed in).
  auth?: Record<string, HarnessHealth["auth"]>;
  noLogin?: string[];
  healthReply?: (id: string) => Promise<unknown>;
  launch?: (method: string) => Promise<unknown>;
  update?: HarnessHealth["update"];
  checking?: boolean;
  refreshed?: string[];
  openTerminal?(): Promise<unknown>;
};

async function renderPage(calls: Call[] = [], closed: string[] = [], page: Page = {}) {
  const container = installDom();
  const catalog = page.acpmux ?? acpmux;
  let reads = 0;
  const native = (method: string, params: Record<string, unknown> = {}) => {
    calls.push({ method, params });
    if (method === "tab.open" && params.kind === "terminal" && page.openTerminal) return page.openTerminal();
    if ((method === "tab.open" || method === "chat.new") && page.launch) return page.launch(method);
    if (method === "harness.health")
      return (
        page.healthReply?.(String(params.id)) ??
        Promise.resolve({
          health: {
            id: params.id,
            auth: page.auth?.[String(params.id)] ?? (params.id === "codex" ? "signedOut" : "signedIn"),
            ...(page.noLogin?.includes(String(params.id)) ? {} : { login: `${String(params.id)} login` }),
            ...(page.update ? { update: page.update } : {}),
          },
        })
      );
    if (method === "shell.run") return Promise.resolve({ id: "run-1" });
    if (method === "shell.read") {
      const output = page.shell?.output ?? [];
      const chunk = output[reads];
      reads += 1;
      if (chunk !== undefined) return Promise.resolve({ output: chunk, next: reads });
      if (page.shell?.endsWithOutput)
        return (page.shell.ends ?? Promise.resolve()).then(() => ({
          output: "more\n",
          next: reads,
        }));
      return (page.shell?.ends ?? Promise.resolve()).then(() => ({
        output: "",
        next: reads,
        exit: { code: page.shell?.code ?? 0 },
      }));
    }
    return Promise.resolve({});
  };
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <HarnessesScreen
        catalog={buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: catalog })}
        acpmux={catalog}
        cwd="/Users/you/src/cmux"
        callNative={native}
        onClose={() => closed.push("closed")}
        refreshCatalog={async () => {
          page.refreshed?.push("catalog");
        }}
        signInPollMs={5}
        {...(page.checking ? { checking: true } : {})}
      />,
    );
  });
  await settle();
  return container;
}

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

/// Yields to the page until `ready()` holds, and fails with what it waited for if it never does.
async function until(ready: () => boolean, what: string) {
  for (let tries = 0; tries < 200 && !ready(); tries++) await settle();
  if (!ready()) throw new Error(`timed out waiting for ${what}`);
}

const status = (container: HTMLElement, name: string) =>
  row(container, name)?.querySelector(".acpmux-harness-detail")?.textContent;

const row = (container: HTMLElement, name: string) =>
  [...container.querySelectorAll<HTMLElement>("[data-harness-row]")].find(
    (element) => element.querySelector(".acpmux-harness-name")?.textContent === name,
  );

test("the page shows each harness's state on this Mac", async () => {
  const container = await renderPage([]);
  const states = Object.fromEntries(
    [...container.querySelectorAll<HTMLElement>("[data-harness-row]")].map((element) => [
      element.querySelector(".acpmux-harness-name")?.textContent,
      element.dataset.harnessStatus,
    ]),
  );
  expect(states).toEqual({
    "Claude Code": "ready",
    Grok: "ready",
    Codex: "signIn",
    "Gemini CLI": "notInstalled",
    OpenCode: "notInstalled",
    Pi: "notInstalled",
    "Vercel AI Gateway": "notInstalled",
  });
});

test("Sign In runs the CLI's login in a terminal tab in the chat's folder", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls);
  await act(async () => row(container, "Codex")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.filter((call) => call.method === "tab.open")).toEqual([
    {
      method: "tab.open",
      // `keep`: the page stays beside the terminal (a page with no chat yet is otherwise replaced).
      params: {
        kind: "terminal",
        text: "codex login",
        cwd: "/Users/you/src/cmux",
        run: true,
        keep: true,
      },
    },
  ]);
});

test("a failed sign-in terminal launch shows its error and retries the same login", async () => {
  const calls: Call[] = [];
  let attempts = 0;
  const container = await renderPage(calls, [], {
    openTerminal: () => {
      attempts += 1;
      return attempts === 1 ? Promise.reject(new Error("Terminal could not open")) : Promise.resolve({});
    },
  });
  const codex = row(container, "Codex")!;
  await act(async () => codex.querySelector<HTMLButtonElement>("button")!.click());
  expect(status(container, "Codex")).toBe("Failed: Terminal could not open");
  expect(codex.querySelector(".acpmux-harness-spinner")).toBeNull();
  expect(codex.querySelector("button")?.textContent).toBe("Sign In");
  await act(async () => codex.querySelector<HTMLButtonElement>("button")!.click());
  expect(attempts).toBe(2);
  expect(codex.dataset.harnessStatus).toBe("waiting");
  const logins = calls.filter((call) => call.method === "tab.open");
  expect(logins[1]).toEqual(logins[0]);
  expect(calls.some((call) => call.method === "chat.new" || call.method === "chat.send")).toBe(false);
});

test("a failed sign-in retries its saved login after health refresh marks the row ready", async () => {
  const calls: Call[] = [];
  let attempts = 0;
  const auth: Record<string, HarnessHealth["auth"]> = { codex: "signedOut" };
  const container = await renderPage(calls, [], {
    auth,
    openTerminal: () => {
      attempts += 1;
      return attempts === 1 ? Promise.reject(new Error("Terminal could not open")) : Promise.resolve({});
    },
  });
  const codex = row(container, "Codex")!;
  await act(async () => codex.querySelector<HTMLButtonElement>("button")!.click());
  expect(status(container, "Codex")).toBe("Failed: Terminal could not open");
  auth.codex = "signedIn";
  // The page's own Event: jsdom refuses the runtime's global one.
  await act(async () => window.dispatchEvent(new window.Event("focus")));
  await until(() => codex.dataset.harnessStatus === "ready", "the refreshed ready row");
  expect(codex.querySelector("button")?.textContent).toBe("Start Chat");
  await act(async () => codex.querySelector<HTMLButtonElement>("button")!.click());
  expect(attempts).toBe(1);
  expect(calls.filter((call) => call.method === "chat.new")).toHaveLength(1);
});

test("Start Chat starts a chat on that harness in this tab", async () => {
  const calls: Call[] = [];
  const closed: string[] = [];
  const container = await renderPage(calls, closed);
  await act(async () => row(container, "Grok")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.filter((call) => call.method === "chat.new")).toEqual([
    { method: "chat.new", params: { harness: "grok", cwd: "/Users/you/src/cmux" } },
  ]);
  expect(closed).toEqual(["closed"]);
});

test("signed out without a login command offers recovery, never Start Chat", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls, [], {
    auth: { claude: "signedOut" },
    noLogin: ["claude"],
  });
  const claude = row(container, "Claude Code")!;
  expect(claude.dataset.harnessStatus).toBe("signIn");
  expect(claude.textContent).toContain("Signed out");
  expect(claude.textContent).not.toContain("Start Chat");
  expect(claude.querySelector("button")!.textContent).toBe("Setup guide");
  await act(async () => claude.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
  expect(calls.find((call) => call.method === "tab.open")?.params.kind).toBe("browser");
});

test("pending health keeps installed rows in place and does not offer Start Chat", async () => {
  let answer!: (reply: unknown) => void;
  const pending = new Promise<unknown>((resolve) => {
    answer = resolve;
  });
  const container = await renderPage([], [], {
    healthReply: (id) => (id === "claude" ? pending : Promise.resolve({ health: { id, auth: "signedIn" } })),
  });
  const names = () =>
    [...container.querySelectorAll("[data-harness-row]")].map((element) => element.getAttribute("data-harness-row"));
  const before = names();
  expect(row(container, "Claude Code")!.dataset.harnessStatus).toBe("checking");
  expect(row(container, "Claude Code")!.querySelector("button")).toBeNull();
  await act(async () => answer({ health: { id: "claude", auth: "signedIn" } }));
  expect(names()).toEqual(before);
  expect(row(container, "Claude Code")!.dataset.harnessStatus).toBe("ready");
});

for (const result of ["rejected", "empty", "unknown"] as const) {
  test(`${result} health offers recovery instead of Ready or an endless check`, async () => {
    const container = await renderPage([], [], {
      healthReply: (id) =>
        result === "rejected"
          ? Promise.reject(new Error("Health unavailable"))
          : Promise.resolve(result === "empty" ? {} : { health: { id, auth: "unknown" } }),
    });
    const claude = row(container, "Claude Code")!;
    expect(claude.dataset.harnessStatus).toBe("unavailable");
    expect(claude.querySelector("button")).not.toBeNull();
    expect(claude.textContent).not.toContain("Start Chat");
    expect(claude.querySelector(".acpmux-harness-spinner")).toBeNull();
  });
}

test("a health answer with no sign-in is unknown: never Ready or Start Chat, and offers a fix", async () => {
  const calls: Call[] = [];
  const closed: string[] = [];
  const container = await renderPage(calls, closed, {
    // acpmux answered, but said nothing about the sign-in (no `auth`).
    healthReply: (id) =>
      Promise.resolve({ health: id === "grok" ? { id, login: "grok login" } : { id, auth: "signedIn" } }),
  });
  const grok = row(container, "Grok")!;
  expect(grok.dataset.harnessStatus).toBe("unavailable");
  expect(grok.textContent).not.toContain("Ready");
  expect(grok.textContent).not.toContain("Start Chat");
  expect(grok.querySelector(".acpmux-harness-spinner")).toBeNull();
  const fix = grok.querySelector<HTMLButtonElement>("button")!;
  expect(["Setup guide", "Check again"]).toContain(fix.textContent ?? "");
  await act(async () => fix.click());
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
  expect(closed).toEqual([]);
  // The known cases keep their actions: signed in starts a chat, signed out signs in.
  expect(row(container, "Claude Code")!.dataset.harnessStatus).toBe("ready");
  expect(row(container, "Claude Code")!.querySelector("button")!.textContent).toBe("Start Chat");
});

for (const [name, method, label] of [
  ["Codex", "tab.open", "Sign In"],
  ["Grok", "chat.new", "Start Chat"],
] as const) {
  test(`${label} rejection stays visible and can be retried`, async () => {
    const calls: Call[] = [];
    const closed: string[] = [];
    let fail = true;
    const container = await renderPage(calls, closed, {
      launch: () => (fail ? Promise.reject(new Error("Host refused launch")) : Promise.resolve({})),
    });
    await act(async () => row(container, name)!.querySelector<HTMLButtonElement>("button")!.click());
    const failed = row(container, name)!;
    expect(failed.dataset.harnessStatus).toBe("failed");
    expect(failed.textContent).toContain("Host refused launch");
    expect(failed.querySelector(".acpmux-harness-spinner")).toBeNull();
    expect(closed).toEqual([]);
    expect(failed.querySelector("button")!.textContent).toBe(label);
    fail = false;
    await act(async () => failed.querySelector<HTMLButtonElement>("button")!.click());
    expect(calls.filter((call) => call.method === method).length).toBe(2);
    if (method === "chat.new") expect(closed).toEqual(["closed"]);
    else expect(row(container, name)!.dataset.harnessStatus).toBe("waiting");
  });
}

test("a pending Start Chat cannot duplicate a launch or close the page early", async () => {
  let answer!: (value: unknown) => void;
  const launch = new Promise<unknown>((resolve) => {
    answer = resolve;
  });
  const calls: Call[] = [];
  const closed: string[] = [];
  const container = await renderPage(calls, closed, { launch: () => launch });
  const button = row(container, "Grok")!.querySelector<HTMLButtonElement>("button")!;
  await act(async () => {
    button.click();
    button.click();
  });
  expect(calls.filter((call) => call.method === "chat.new").length).toBe(1);
  expect(closed).toEqual([]);
  expect(button.disabled).toBe(true);
  await act(async () => answer({}));
  expect(closed).toEqual(["closed"]);
});

test("Install… opens the setup page of a harness with no install command in a browser tab", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls);
  await act(async () => row(container, "Pi")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.filter((call) => call.method === "tab.open")).toEqual([
    {
      method: "tab.open",
      params: { kind: "browser", text: "https://github.com/earendil-works/pi", keep: true },
    },
  ]);
});

test("Install runs the install command in place, shows its progress, then checks the harness again", async () => {
  const calls: Call[] = [];
  const refreshed: string[] = [];
  let end = () => {};
  const ends = new Promise<void>((resolve) => (end = resolve));
  const container = await renderPage(calls, [], {
    shell: { output: ["npm warn deprecated\n", "added 1 package in 3s\n"], code: 0, ends },
    refreshed,
  });
  await act(async () => row(container, "OpenCode")!.querySelector<HTMLButtonElement>("button")!.click());
  // In place: no terminal or browser tab, and the row says it is installing.
  expect(calls.filter((call) => call.method === "tab.open")).toEqual([]);
  expect(calls.find((call) => call.method === "shell.run")?.params).toEqual({
    command: INSTALL_COMMANDS.opencode,
    cwd: "/Users/you/src/cmux",
  });
  await until(() => status(container, "OpenCode") === "added 1 package in 3s", "the second output line");
  const installing = row(container, "OpenCode")!;
  expect(installing.dataset.harnessStatus).toBe("installing");
  expect(installing.querySelector(".acpmux-harness-detail")?.textContent).toBe("added 1 package in 3s");
  expect(installing.querySelectorAll("button").length).toBe(0);
  end();
  await until(() => refreshed.length > 0, "the catalog read after the install");
  // Done: acpmux looks for harnesses again (`rescan`) and the page reads its catalog again.
  expect(calls.filter((call) => call.method === "harness.health" && call.params.id === "opencode")).toEqual([
    { method: "harness.health", params: { id: "opencode", refresh: true, rescan: true } },
  ]);
  expect(refreshed).toEqual(["catalog"]);
});

test("an install acpmux still cannot find afterwards says so, never offers Install again", async () => {
  const container = await renderPage([], [], {
    shell: { output: ["added 1 package in 3s\n"], code: 0 },
  });
  await act(async () => row(container, "OpenCode")!.querySelector<HTMLButtonElement>("button")!.click());
  await until(() => row(container, "OpenCode")!.dataset.harnessStatus === "failed", "the install to end");
  const after = row(container, "OpenCode")!;
  expect(after.dataset.harnessStatus).toBe("failed");
  expect(after.querySelector(".acpmux-harness-detail")?.textContent).toBe("Finished, but cmux can't run it yet");
  expect([...after.querySelectorAll("button")].map((button) => button.textContent)).toEqual(["Setup guide"]);
});

test("unmounting the page stops an install it started", async () => {
  const calls: Call[] = [];
  let end = () => {};
  const ends = new Promise<void>((resolve) => (end = resolve));
  const container = await renderPage(calls, [], {
    shell: { output: ["fetching\n"], code: 0, ends, endsWithOutput: true },
  });
  await act(async () => row(container, "OpenCode")!.querySelector<HTMLButtonElement>("button")!.click());
  // The second read waits on the command, which is still running.
  await until(() => calls.filter((call) => call.method === "shell.read").length === 2, "the second read");
  await act(async () => root!.unmount());
  root = undefined;
  end();
  await until(() => calls.some((call) => call.method === "shell.stop"), "the command to stop");
  expect(calls.some((call) => call.method === "shell.stop")).toBe(true);
  expect(calls.some((call) => call.params.rescan === true)).toBe(false);
});

test("an install that fails says why and offers one fix: the setup page", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls, [], {
    shell: { output: ["npm error code EACCES\n", "npm error permission denied\n"], code: 243 },
  });
  await act(async () => row(container, "OpenCode")!.querySelector<HTMLButtonElement>("button")!.click());
  await until(() => row(container, "OpenCode")!.dataset.harnessStatus === "failed", "the install to fail");
  const failed = row(container, "OpenCode")!;
  expect(failed.dataset.harnessStatus).toBe("failed");
  expect(failed.querySelector(".acpmux-harness-detail")?.textContent).toContain("npm error permission denied");
  const buttons = failed.querySelectorAll<HTMLButtonElement>("button");
  expect(buttons.length).toBe(1);
  await act(async () => buttons[0]!.click());
  expect(calls.filter((call) => call.method === "tab.open")).toEqual([
    {
      method: "tab.open",
      params: { kind: "browser", text: "https://opencode.ai/docs", keep: true },
    },
  ]);
});

test("after Sign In the row waits for the sign-in and turns ready by itself", async () => {
  const calls: Call[] = [];
  const auth: Record<string, HarnessHealth["auth"]> = { codex: "signedOut" };
  const container = await renderPage(calls, [], { auth });
  await act(async () => row(container, "Codex")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(row(container, "Codex")!.dataset.harnessStatus).toBe("waiting");
  // A poll starts only after the one before it answered: two polls means one signed-out answer landed.
  const polls = () =>
    calls.filter((call) => call.method === "harness.health" && call.params.id === "codex" && call.params.refresh)
      .length;
  await until(() => polls() >= 2, "a signed-out answer");
  expect(row(container, "Codex")!.dataset.harnessStatus).toBe("waiting");
  // The login finishes in its terminal tab; no focus change needed.
  auth.codex = "signedIn";
  await until(() => row(container, "Codex")!.dataset.harnessStatus === "ready", "the row to turn ready");
  expect(row(container, "Codex")!.dataset.harnessStatus).toBe("ready");
  const checks = calls.filter((call) => call.method === "harness.health" && call.params.id === "codex");
  expect(checks.at(-1)?.params).toEqual({ id: "codex", refresh: true });
});

test("an expired sign-in is never Ready: the row offers Sign In and waits while it stays expired", async () => {
  const calls: Call[] = [];
  const auth: Record<string, HarnessHealth["auth"]> = { claude: "expired", codex: "signedIn" };
  const container = await renderPage(calls, [], { auth });
  expect(row(container, "Claude Code")!.dataset.harnessStatus).toBe("signIn");
  await act(async () => row(container, "Claude Code")!.querySelector<HTMLButtonElement>("button")!.click());
  const polls = () =>
    calls.filter((call) => call.method === "harness.health" && call.params.id === "claude" && call.params.refresh)
      .length;
  await until(() => polls() >= 2, "an expired answer");
  expect(row(container, "Claude Code")!.dataset.harnessStatus).toBe("waiting");
  auth.claude = "signedIn";
  await until(() => row(container, "Claude Code")!.dataset.harnessStatus === "ready", "the row to turn ready");
});

test("a harness acpmux cannot run says why, with one fix action", async () => {
  const broken: AcpmuxSnapshot["catalog"] = [
    ...acpmux,
    {
      id: "opencode",
      name: "OpenCode",
      family: "opencode",
      models: [],
      unavailable: "opencode 0.3.1 is too old: acpmux needs 0.4 or later\nrun opencode upgrade",
    },
  ];
  const calls: Call[] = [];
  const container = await renderPage(calls, [], {
    acpmux: broken,
    update: { command: "npm install -g opencode-ai@latest", elevated: false },
  });
  const unavailable = row(container, "OpenCode")!;
  expect(unavailable.dataset.harnessStatus).toBe("unavailable");
  expect(unavailable.querySelector(".acpmux-harness-detail")?.textContent).toBe(
    "opencode 0.3.1 is too old: acpmux needs 0.4 or later",
  );
  const buttons = unavailable.querySelectorAll<HTMLButtonElement>("button");
  expect([...buttons].map((button) => button.textContent)).toEqual(["Update"]);
  await act(async () => buttons[0]!.click());
  expect(calls.find((call) => call.method === "shell.run")?.params).toEqual({
    command: "npm install -g opencode-ai@latest",
    cwd: "/Users/you/src/cmux",
  });
});

test("before acpmux has answered, the page says it is checking, never Not installed", async () => {
  const container = await renderPage([], [], { acpmux: [], checking: true });
  const states = [...container.querySelectorAll<HTMLElement>("[data-harness-row]")].map(
    (element) => element.dataset.harnessStatus,
  );
  expect(states.length).toBeGreaterThan(0);
  expect(new Set(states)).toEqual(new Set(["checking"]));
  expect(container.querySelectorAll("[data-harness-row] button").length).toBe(0);
});

test("Custom harness… starts the harness guide chat in this tab, never another action", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls);
  await act(async () => {
    container.querySelector<HTMLButtonElement>("[data-harness-custom]")!.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const started = calls.filter((call) => call.method !== "harness.health");
  expect(started.map((call) => call.method)).toEqual(["chat.new", "chat.send"]);
  expect(started[0]!.params).toEqual({ cwd: "/Users/you/src/cmux" });
  expect(String(started[1]!.params.text)).toContain("cmux harness guide");
});

test("the New Tab page has no Integrate a harness button (and no tools row)", async () => {
  const container = installDom();
  Object.assign(dom!.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const noop = () => {};
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={{ ...noChat(), catalog: acpmux }}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    );
  });
  // The calm default New Tab has no tools row (Leo 2026-10-11).
  expect(container.querySelector(".nt-tools")).toBeNull();
  expect(container.querySelector(".nt-no-agent, .acpmux-add-harness")).toBeNull();
});
