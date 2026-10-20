// The session side rail (cx-ncc.101, Debug Settings `agent.sessionRail`, Claude Code desktop parity): with the flag
// on, a header button opens a rail beside the chat with where the session runs and its folders
// (Environment), how much of the context window it used (Context) and the files it changed
// (Outputs), each of which opens its diff. With the flag off the pane has neither the button nor
// the rail.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useSessionRail } from "../src/agent-session/acpmux/summary/SessionRail";
import { activity, chat, tool } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(sessionRail: boolean): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  // The App pushes Debug Settings `agent.sessionRail` with the header state.
  setHeaderState({ sessionRail });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    // Base UI's Collapsible schedules its open and close on animation frames.
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
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

const noop = () => undefined;

/// The pane's pieces as App.tsx places them: the button in the header's actions, the rail beside
/// the chat column.
function Pane({ snapshot, onOpenOutput }: { snapshot: AcpmuxSnapshot; onOpenOutput: (path: string) => void }) {
  const { button, rail } = useSessionRail({ snapshot, machineName: "Studio", onOpenOutput });
  return (
    <section className="acpmux-shell">
      <div className="acpmux-main">
        <header className="acpmux-header">
          <ChatHeaderTools
            onTerminal={noop}
            onBrowser={noop}
            summary={null as ReactNode}
            menu={() => []}
            sessionRail={button}
          />
        </header>
      </div>
      {rail}
    </section>
  );
}

const CWD = "/Users/you/src/atlas-web";
const edited = (path: string, oldText: string | undefined, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, oldText, newText }] });

const localChat = chat([
  activity([edited("src/fetch.ts", "a\n", "a\nb\n"), edited("src/retry.ts", undefined, "x\ny\nz\n")], 3),
]);

async function render(container: HTMLElement, snapshot: AcpmuxSnapshot, opened: string[] = []) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Pane snapshot={snapshot} onOpenOutput={(path) => opened.push(path)} />);
  });
  return opened;
}

const toggle = (container: HTMLElement) =>
  container.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Session details"]');
const rail = (container: HTMLElement) => container.querySelector<HTMLElement>("aside.acpmux-rail");
const card = (container: HTMLElement, name: string) =>
  [...container.querySelectorAll<HTMLElement>(".acpmux-rail-card")].find(
    (element) => element.querySelector(".acpmux-rail-card__title")?.textContent === name,
  );
const click = (element: HTMLElement) => act(async () => element.click());

test("the header's toggle opens a rail with the session's environment, context use and outputs", async () => {
  const container = installDom(true);
  const opened = await render(container, localChat);
  expect(rail(container)).toBeNull();
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("false");
  await click(toggle(container)!);
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("true");
  expect(rail(container)).not.toBeNull();
  // The cards in order.
  expect([...container.querySelectorAll(".acpmux-rail-card__title")].map((element) => element.textContent)).toEqual([
    "Environment",
    "Context",
    "Outputs",
  ]);

  // Environment: this Mac by its name, the folder with its parent home-abbreviated, the branch.
  const environment = card(container, "Environment")!;
  const rows = [...environment.querySelectorAll(".acpmux-rail-row")].map((row) => row.textContent);
  expect(rows[0]).toBe("Studio");
  expect(rows[1]).toContain("atlas-web");
  expect(rows[1]).toContain("~/src");
  expect(rows).toContain("main");

  // Context: 48K of 200K is 24%, collapsed until asked; then the tokens.
  const context = card(container, "Context")!;
  expect(context.textContent).toContain("24%");
  expect(context.textContent).not.toContain("tokens");
  await click(context.querySelector<HTMLElement>("button")!);
  expect(card(container, "Context")!.textContent).toMatch(/48K of 200K tokens/);

  // Outputs: the changed and the created file, each opening its diff by path.
  const outputs = card(container, "Outputs")!;
  const files = [...outputs.querySelectorAll<HTMLElement>(".acpmux-rail-output")];
  expect(files.map((file) => file.querySelector(".acpmux-rail-row__name")?.textContent)).toEqual([
    "fetch.ts",
    "retry.ts",
  ]);
  expect(files[1]!.textContent).toContain("+3");
  await click(files[1]!);
  expect(opened).toEqual([`${CWD}/src/retry.ts`]);

  // The toggle closes it again.
  await click(toggle(container)!);
  expect(rail(container)).toBeNull();
});

test("a cloud session names its host; no usage reads a dash; no edits say so", async () => {
  const container = installDom(true);
  const base = chat([]);
  await render(container, {
    ...base,
    summary: { ...base.summary!, host: "build-01", hostKind: "cloud", usage: undefined },
  });
  await click(toggle(container)!);
  const environment = card(container, "Environment")!;
  expect(environment.querySelector(".acpmux-rail-row")?.textContent).toBe("build-01");
  const context = card(container, "Context")!;
  expect(context.textContent).toContain("—");
  // Nothing to expand without usage.
  expect(context.querySelector("button")).toBeNull();
  expect(card(container, "Outputs")!.textContent).toContain("No files changed yet");
});

test("with the toggle off there is no toggle button and no rail", async () => {
  const container = installDom(false);
  await render(container, localChat);
  expect(toggle(container)).toBeNull();
  expect(rail(container)).toBeNull();
  expect(container.querySelector(".acpmux-rail-card")).toBeNull();
});

test("an output whose diff narrows the pane under the overlay width closes the rail", async () => {
  const container = installDom(true);
  // The pane is the page's viewport: a diff opened beside the chat narrows it.
  let narrow = false;
  const listeners = new Set<() => void>();
  const query = {
    get matches() {
      return narrow;
    },
    addEventListener: (_: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_: string, listener: () => void) => listeners.delete(listener),
  };
  dom!.window.matchMedia = (() => query) as unknown as typeof window.matchMedia;
  const opened = await render(container, localChat);
  await click(toggle(container)!);
  const files = [...card(container, "Outputs")!.querySelectorAll<HTMLElement>(".acpmux-rail-output")];
  await click(files[0]!);
  expect(opened).toEqual([`${CWD}/src/fetch.ts`]);
  await act(async () => {
    narrow = true;
    for (const listener of listeners) listener();
  });
  // Over the chat it would cover the diff's other half; the toggle still opens it.
  expect(rail(container)).toBeNull();
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("false");
});

test("a harness that reports its MCP servers gets a Connectors card; one that does not, none", async () => {
  const container = installDom(true);
  const base = chat([]);
  await render(container, {
    ...base,
    summary: {
      ...base.summary!,
      mcpServers: [
        { name: "github", status: "connected" },
        { name: "linear", status: "failed" },
        { name: "sentry", status: "pending" },
      ],
    },
  });
  await click(toggle(container)!);
  expect([...container.querySelectorAll(".acpmux-rail-card__title")].map((element) => element.textContent)).toEqual([
    "Environment",
    "Context",
    "Connectors",
    "Outputs",
  ]);
  // Folded to the count of the connected ones; open, each server with its state when not connected.
  const connectors = card(container, "Connectors")!;
  expect(connectors.textContent).toContain("1 connected");
  expect(connectors.querySelector(".acpmux-rail-row")).toBeNull();
  await click(connectors.querySelector<HTMLElement>("button")!);
  const rows = [...card(container, "Connectors")!.querySelectorAll(".acpmux-rail-row")].map((row) => row.textContent);
  expect(rows).toEqual(["github", "linearFailed", "sentryConnecting"]);

  // A harness that reports no servers (every ACP one) has no card, not an empty one.
  await render(container, base);
  expect(card(container, "Connectors")).toBeUndefined();
});
