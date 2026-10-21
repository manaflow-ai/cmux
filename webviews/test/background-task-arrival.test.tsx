// l10n-allow-file: test fixture commands, not shipped UI.
// A background task that starts while its list is drawn enters it (Leo 2026-10-20, directional
// motion): its row carries `data-enter="top"` (the lists are newest first), which ui/popupSurface.css
// plays once on mount, on the host's motion tokens. The rows a list is drawn with are simply there,
// so opening the Inspector, the Summary or the finished fold never replays every row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { BackgroundCommand } from "../src/agent-session/acpmux/inspector/processes";
import { TasksSection } from "../src/agent-session/acpmux/inspector/TasksSection";
import { SummaryTasks } from "../src/agent-session/acpmux/summary/SummaryTasks";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
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

const command = (id: string, text: string, state: BackgroundCommand["state"] = "running"): BackgroundCommand => ({
  id,
  command: text,
  state,
  startedAt: 1_000,
  ...(state === "running" ? {} : { endedAt: 2_000 }),
});

const entering = (container: HTMLElement, selector: string) =>
  [...container.querySelectorAll<HTMLElement>(selector)].map(
    (row) =>
      `${row.textContent?.includes("pytest") ? "pytest" : row.textContent?.includes("tsc") ? "tsc" : "?"}:${row.dataset.enter ?? "-"}`,
  );

test("the Inspector's new running task enters from the top; the ones it was drawn with do not", async () => {
  const container = installDom();
  const first = [command("a", "tsc --watch")];
  await act(async () => {
    root = createRoot(container);
    root.render(<TasksSection commands={first} />);
  });
  expect(entering(container, "li.acpmux-chat-inspector-task--command")).toEqual(["tsc:-"]);
  await act(async () => root!.render(<TasksSection commands={[command("b", "pytest -x"), ...first]} />));
  expect(entering(container, "li.acpmux-chat-inspector-task--command")).toEqual(["pytest:top", "tsc:-"]);
});

test("the Summary's new running task enters from the top; the ones it was drawn with do not", async () => {
  const container = installDom();
  const first = [command("a", "tsc --watch")];
  await act(async () => {
    root = createRoot(container);
    root.render(<SummaryTasks commands={first} />);
  });
  expect(entering(container, "li.acpmux-summary-task")).toEqual(["tsc:-"]);
  await act(async () => root!.render(<SummaryTasks commands={[command("b", "pytest -x"), ...first]} />));
  expect(entering(container, "li.acpmux-summary-task")).toEqual(["pytest:top", "tsc:-"]);
});

test("opening the finished fold does not replay its rows", async () => {
  const container = installDom();
  const commands = [command("a", "tsc --watch", "completed")];
  await act(async () => {
    root = createRoot(container);
    root.render(<TasksSection commands={commands} />);
  });
  const fold = container.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-fold")!;
  await act(async () => fold.click());
  expect(entering(container, "li.acpmux-chat-inspector-task--command")).toEqual(["tsc:-"]);
});

// Custom properties inherit, so a row's entrance must not pick up the axis or the travel of the
// surface it sits in (the Summary card enters from the right, and travels 100% inline): each edge
// sets both axes, and a surface inside another entering surface starts from the default distance.
test("an entering row inside an entering card keeps its own edge and distance", async () => {
  const css = await Bun.file(new URL("../src/ui/popupSurface.css", import.meta.url)).text();
  const rule = (selector: string) =>
    css.match(new RegExp(`${selector.replace(/[[\]()"]/g, "\\$&")}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
  for (const edge of ["right", "left", "bottom", "top"]) {
    const body = rule(`:where([data-enter="${edge}"])`);
    expect(body).toContain("--ui-enter-x:");
    expect(body).toContain("--ui-enter-y:");
  }
  expect(rule(":where([data-enter] [data-enter])")).toContain("--ui-enter-distance: 8px");
});
