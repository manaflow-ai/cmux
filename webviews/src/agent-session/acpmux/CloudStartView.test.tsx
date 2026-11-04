// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// A chat starting in Cloud (CloudStartView.tsx): the message, a spinner while it starts (never a
// pulsing dot), the facts known so far, and a failure in the host's words; each arm of the
// `cloud-start-look` experiment draws the same facts.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { CloudStartView, startupChecklist } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "MouseEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

const start: CloudStartProgress = {
  key: "k",
  task: "fix the build",
  state: "starting",
  folder: "paint",
  step: "folder",
  machine: "paint-dev",
  size: "4 CPU",
  secrets: 2,
  network: "limited",
};

const arm = (name: string) => {
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "cloud-start-look": name };
};
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
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

test("every arm shows the message and compact preparing status", () => {
  for (const name of ["chips", "rows", "steps"]) {
    arm(name);
    const html = renderToStaticMarkup(<CloudStartView start={start} />);
    expect(html).toContain(`data-look="${name}"`);
    expect(html).toContain("fix the build");
    expect(html).toContain('class="acpmux-cloud-start__status"');
    expect(html).toContain("cv-spinner");
    expect(html).not.toContain('data-step-id="machine"');
  }
});

test("a failed start opens the details disclosure with the host facts", () => {
  const html = renderToStaticMarkup(
    <CloudStartView start={{ ...start, state: "failed", message: "No machine free" }} />,
  );
  expect(html).toContain('aria-expanded="true"');
  expect(html).toContain('data-step-id="machine"');
  for (const fact of ["paint", "paint-dev · 4 CPU", ">2<", "Limited"]) expect(html).toContain(fact);
});

test("a healthy start opens its details when the disclosure is requested", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<CloudStartView start={start} />);
  });
  const summary = container.querySelector<HTMLButtonElement>(".acpmux-cloud-start__summary");
  expect(summary?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => summary?.click());
  expect(summary?.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector('[data-step-id="machine"]')).toBeTruthy();
});

test("the steps arm keeps its legacy step list behind the disclosure", () => {
  arm("steps");
  const html = renderToStaticMarkup(<CloudStartView start={start} />);
  expect(html).not.toContain('data-step="done"');
  expect(html).not.toContain('data-step="current"');
  expect(html).not.toContain('data-step="next"');
});

test("a failure says the host's words with no spinner, and the New Tab page draws no bubble", () => {
  const html = renderToStaticMarkup(
    <CloudStartView start={{ ...start, state: "failed", message: "No machine free" }} bubble={false} />,
  );
  expect(html).toContain('role="alert"');
  expect(html).toContain("No machine free");
  expect(html).not.toContain("cv-spinner");
  expect(html).not.toContain("fix the build");
});

test("the startup checklist skips clone without a repository and explains a missing script", () => {
  const rows = startupChecklist({
    key: "k",
    task: "hi",
    state: "starting",
    home: true,
    setup: { state: "skipped", hasScript: false },
  });
  expect(rows.map((row) => row.status)).toEqual(["pending", "skipped", "skipped", "pending"]);
  expect(rows[2]?.action).toBe(true);
  expect(rows[2]?.detail).toContain("Add a setup script");
});

test("environment setup status maps cached, running and failed states", () => {
  const base = { key: "k", task: "hi", state: "starting" as const };
  expect(startupChecklist({ ...base, setup: { state: "done", status: "ready" } })[2]?.detail).toBe("cached");
  expect(startupChecklist({ ...base, setup: { state: "running", status: "building" } })[2]?.status).toBe("running");
  expect(
    startupChecklist({ ...base, setup: { state: "failed", status: "failed", logTail: "npm ERR!" } })[2],
  ).toMatchObject({ status: "error", logTail: "npm ERR!" });
});

test("clone status keeps seed phase and object progress in the row", () => {
  const rows = startupChecklist({
    key: "k",
    task: "hi",
    state: "starting",
    hasRepository: true,
    clone: {
      state: "running",
      phase: "Receiving objects",
      progress: { objects: 2, totalObjects: 4, receivedBytes: 2048 },
    },
  });
  expect(rows[1]?.detail).toBe("Receiving objects · 50%");
});

test("the clone row words each part of a seed and of a copy", () => {
  const row = (clone: NonNullable<CloudStartProgress["clone"]>) =>
    startupChecklist({ key: "k", task: "hi", state: "starting", hasRepository: true, clone }, undefined, 0, "en")[1];
  expect(
    row({ state: "running", phase: "upload", progress: { receivedBytes: 1024, bytesTotal: 12 * 1024 * 1024 } })?.detail,
  ).toBe("Sending your changes (12 MB)");
  expect(row({ state: "running", phase: "clone", progress: { objects: 41, totalObjects: 100 } })?.detail).toBe(
    "Cloning from GitHub · 41%",
  );
  expect(row({ state: "running", phase: "checkout" })?.detail).toBe("Checking out files");
  expect(
    row({
      state: "running",
      phase: "copy",
      fallback: "not_git",
      progress: { filesDone: 1204, filesTotal: 8310, receivedBytes: 312 * 1024 * 1024, bytesTotal: 2.1 * 1024 ** 3 },
    })?.detail,
  ).toBe("Copying the folder instead · 1,204 of 8,310 files · 312 MB of 2.1 GB");
  expect(row({ state: "done", phase: "complete" })?.detail).toBeUndefined();
  expect(row({ state: "done", phase: "complete", fallback: "not_git" })?.detail).toBe("Copying the folder instead");
});

test("a seed that needs the GitHub App links its install from the clone row", () => {
  const rows = startupChecklist(
    {
      key: "k",
      task: "hi",
      state: "starting",
      hasRepository: true,
      clone: {
        state: "running",
        phase: "copy",
        fallback: "seed.needs_github",
        installUrl: "https://github.com/apps/cmux/installations/new",
      },
    },
    undefined,
    0,
    "en",
  );
  expect(rows[1]?.link).toEqual({
    href: "https://github.com/apps/cmux/installations/new",
    label: "Install the cmux GitHub App to clone it next time",
  });
});

test("a machine failure stops a clone spinner", () => {
  const rows = startupChecklist({
    key: "k",
    task: "hi",
    state: "failed",
    step: "machine",
    hasRepository: true,
    clone: { state: "running" },
  });
  expect(rows[0]?.status).toBe("error");
  expect(rows[1]?.status).toBe("pending");
});

test("a missing setup script is plain text without an environment callback", () => {
  const html = renderToStaticMarkup(
    <CloudStartView
      start={{
        key: "k",
        task: "hi",
        state: "failed",
        step: "opening",
        home: true,
        setup: { state: "skipped", hasScript: false },
      }}
    />,
  );
  expect(html).toContain("Add a setup script to install dependencies and configure your environment.");
  expect(html).not.toContain('class="acpmux-cloud-start__link"');
});

test("initialized sessions collapse to one quiet line", () => {
  const html = renderToStaticMarkup(
    <CloudStartView start={{ key: "k", task: "hi", state: "starting", initialized: true }} />,
  );
  expect(html).toContain("Initialized session");
  expect(html).toContain('class="acpmux-cloud-start__status acpmux-cloud-start__status--ready"');
  expect(html).not.toContain('data-step-id="machine"');
});

test("startup durations use the supplied clock", () => {
  const rows = startupChecklist({ key: "k", task: "hi", state: "starting", machineStartedAt: 1_000 }, undefined, 3_500);
  expect(rows[0]?.duration).toBe("2.5s");
});

test("setup hint becomes a link when an environment callback is provided", () => {
  const html = renderToStaticMarkup(
    <CloudStartView
      start={{
        key: "k",
        task: "hi",
        state: "failed",
        step: "opening",
        home: true,
        setup: { state: "skipped", hasScript: false },
      }}
      onOpenEnvironment={() => undefined}
    />,
  );
  expect(html).toContain('class="acpmux-cloud-start__link"');
});

test("the harness row says Starting until the harness has started", () => {
  const running = startupChecklist({ key: "k", task: "hi", state: "starting", step: "opening", agent: "Claude" });
  expect(running[3]?.status).toBe("running");
  expect(running[3]?.label).toBe("Starting Claude");
  const waiting = startupChecklist({ key: "k", task: "hi", state: "starting", agent: "Claude" });
  expect(waiting[3]?.label).toBe("Starting Claude");
  const done = startupChecklist({ key: "k", task: "hi", state: "starting", initialized: true, agent: "Claude" });
  expect(done[3]?.label).toBe("Started Claude");
});

test("row state words are screen-reader only, hidden by the card's own sheet", async () => {
  const css = await Bun.file(new URL("./cloudStart.css", import.meta.url)).text();
  expect(css).toMatch(/\.acpmux-cloud-start \.visually-hidden\s*\{[^}]*clip: rect\(0 0 0 0\)/);
  const html = renderToStaticMarkup(
    <CloudStartView start={{ key: "k", task: "hi", state: "failed", step: "opening", machineStartedAt: 1_000 }} />,
  );
  expect(html).toContain('<span class="visually-hidden">');
});

test("a start this Mac refused before it reached Cloud marks no step failed", () => {
  const failed = { key: "k", task: "hey", state: "failed" as const, folder: "paint" };
  expect(startupChecklist(failed)[0]?.status).toBe("error");
  expect(startupChecklist({ ...failed, refusedHere: true }).map((row) => row.status)).not.toContain("error");
});
