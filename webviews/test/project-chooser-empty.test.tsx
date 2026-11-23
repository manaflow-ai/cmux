// The project picker with no projects yet (dogfood run, hq #1893): before anything was typed it said
// "No matching projects", as if a search had found nothing. With no search it now says there are no
// recent projects; a search that finds nothing still says no projects match.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { until } from "./support/until";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "Element",
  "getComputedStyle",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

test("the project picker with no projects says none are recent until a search finds nothing", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  root = createRoot(host);
  await act(async () =>
    root!.render(<ProjectChooser projects={[]} icon={null} onPick={() => {}} onBrowse={() => {}} side="bottom" />),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  const empty = () => document.querySelector(".acpmux-project-empty")?.textContent;
  expect(empty()).toBe("No recent folders");

  const search = document.querySelector<HTMLInputElement>('input[role="combobox"]')!;
  const setValue = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(search, "payments");
    search.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  expect(empty()).toBe("No matching folders");
});

// Add folder… goes straight to the host's folder panel. A refused panel says why beside a Retry
// (review of cmux#36964: the Add project dialog that showed it is gone).
test("a failed Add folder… says why and Retry asks the host again", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  act(() => root?.unmount());
  root = createRoot(host);
  let calls = 0;
  const onBrowse = () => {
    calls += 1;
    return calls === 1 ? Promise.reject(new Error("Folder access was denied")) : Promise.resolve(undefined);
  };
  await act(async () =>
    root!.render(<ProjectChooser projects={[]} icon={null} onPick={() => {}} onBrowse={onBrowse} side="bottom" />),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  const add = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((option) =>
    option.textContent?.includes("Add folder…"),
  )!;
  await act(async () => add.click());
  await until(
    () => host.querySelector('[role="alert"]') !== null,
    () => act(async () => {}),
  );
  expect(calls).toBe(1);
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("Folder access was denied");

  const retry = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === "Retry",
  )!;
  // The retry's ask and its answer are promise steps: the act returns only after a task turn, when
  // they have run.
  await act(async () => retry.click());
  expect(calls).toBe(2);
  expect(host.querySelector('[role="alert"]')).toBeNull();
});

// A folder picked while the host's folder panel is still open wins over the panel's late answer
// (review of cmux#36964): the panel only answers (deferPick) and the chooser commits the pick.
test("a folder picked while Add folder… is open is not replaced by the panel's late answer", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  act(() => root?.unmount());
  root = createRoot(host);
  let answer: (cwd: string) => void = () => {};
  const requests: unknown[] = [];
  const picks: string[] = [];
  const onBrowse = (request?: unknown) => {
    requests.push(request);
    return new Promise<string>((resolve) => (answer = resolve));
  };
  const projects = [{ cwd: "/work/relay", label: "relay" }];
  await act(async () =>
    root!.render(
      <ProjectChooser
        projects={projects}
        icon={null}
        onPick={(cwd) => picks.push(cwd)}
        onBrowse={onBrowse}
        side="bottom"
      />,
    ),
  );
  const option = (name: string) =>
    [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) => row.textContent?.includes(name))!;
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  await act(async () => option("Add folder…").click());
  expect(requests).toEqual([{ deferPick: true }]);

  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  await act(async () => option("relay").click());
  expect(picks).toEqual(["/work/relay"]);

  // The panel's late answer and its handling are promise steps: the act returns only after a task
  // turn, when they have run.
  await act(async () => answer("/work/late"));
  expect(picks).toEqual(["/work/relay"]);
});

// Leo, 2026-11-09: "this no folder selected should be, like, good as well." With no folder, the
// chooser's face reads No folder, and its menu checks No folder too, also before the caller says
// `noProject` (a fresh New Tab headline); a picked folder unchecks it (review of cmux#39940).
test("the empty chooser reads No folder and its menu checks No folder", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  const projects = [{ cwd: "/Users/you/src/cmux", label: "cmux" }];
  const noneRow = () =>
    [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((option) =>
      option.textContent?.startsWith("No folder"),
    );
  for (const current of [undefined, "/Users/you/src/cmux"]) {
    act(() => root?.unmount());
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ProjectChooser
          projects={projects}
          {...(current ? { current, currentLabel: "cmux" } : {})}
          icon={null}
          onPick={() => {}}
          onNoProject={() => {}}
          side="bottom"
        />,
      ),
    );
    const trigger = host.querySelector<HTMLButtonElement>("button")!;
    expect(trigger.textContent).toBe(current ? "cmux" : "No folder");
    await act(async () => trigger.click());
    expect(noneRow(), "the No folder row").toBeTruthy();
    expect(noneRow()!.getAttribute("aria-current")).toBe(current ? null : "true");
    await act(async () => trigger.click());
  }
});
