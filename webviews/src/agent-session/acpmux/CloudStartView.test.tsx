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
      start={{ key: "k", task: "hi", state: "starting", home: true, setup: { state: "skipped", hasScript: false } }}
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
  expect(html).not.toContain('data-step-id="machine"');
});

test("startup durations use the supplied clock", () => {
  const rows = startupChecklist({ key: "k", task: "hi", state: "starting", machineStartedAt: 1_000 }, undefined, 3_500);
  expect(rows[0]?.duration).toBe("2.5s");
});

test("setup hint becomes a link when an environment callback is provided", () => {
  const html = renderToStaticMarkup(
    <CloudStartView
      start={{ key: "k", task: "hi", state: "starting", home: true, setup: { state: "skipped", hasScript: false } }}
      onOpenEnvironment={() => undefined}
    />,
  );
  expect(html).toContain('class="acpmux-cloud-start__link"');
});
