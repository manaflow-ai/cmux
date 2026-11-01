// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// A chat starting in Cloud (CloudStartView.tsx): the message, a spinner while it starts (never a
// pulsing dot), the facts known so far, and a failure in the host's words; each arm of the
// `cloud-start-look` experiment draws the same facts.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { CloudStartView, startupChecklist } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";

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
afterEach(() => {
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

test("every arm shows the message, a spinner and the same facts", () => {
  for (const name of ["chips", "rows", "steps"]) {
    arm(name);
    const html = renderToStaticMarkup(<CloudStartView start={start} />);
    expect(html).toContain(`data-look="${name}"`);
    expect(html).toContain("fix the build");
    expect(html).toContain("cv-spinner");
    for (const fact of ["paint", "paint-dev · 4 CPU", ">2<", "Limited"]) expect(html).toContain(fact);
  }
});

test("the steps arm marks the steps done, current and next", () => {
  arm("steps");
  const html = renderToStaticMarkup(<CloudStartView start={start} />);
  expect(html.match(/data-step="done"/g)).toHaveLength(1);
  expect(html.match(/data-step="current"/g)).toHaveLength(1);
  expect(html.match(/data-step="next"/g)).toHaveLength(1);
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
  expect(rows[1]?.detail).toBe("Receiving objects · 2/4 objects · 2 KB");
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
      start={{ key: "k", task: "hi", state: "starting", home: true, setup: { state: "skipped", hasScript: false } }}
    />,
  );
  expect(html).toContain("Add a setup script to install dependencies and configure your environment.");
  expect(html).not.toContain('class="acpmux-cloud-start__link"');
});
