// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// A chat starting in Cloud (CloudStartView.tsx): the message, a spinner while it starts (never a
// pulsing dot), the facts known so far, and a failure in the host's words; each arm of the
// `cloud-start-look` experiment draws the same facts.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { CloudStartView } from "./CloudStartView";
import { startupChecklist } from "./cloudStartViewModel";
import cloudStartGallery from "./CloudStartView.gallery";
import type { CloudStartProgress } from "./cloudStartProgress";
import { createGitHubPicker, githubFullName } from "./githubRepos";
import { settleReact } from "../../../test/support/domTeardown";

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

// The experiments global as the file found it (the test preload may set one): put back after each test, never deleted.
const experimentsAtStart = Object.getOwnPropertyDescriptor(globalThis, "cmuxExperiments");
const arm = (name: string) => {
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "cloud-start-look": name };
};
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  if (experimentsAtStart) Object.defineProperty(globalThis, "cmuxExperiments", experimentsAtStart);
  else delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

test("a start on its way reads as a local first turn: the message and the Thinking line, no Cloud rows", () => {
  for (const s of [start, { ...start, initialized: true }]) {
    const html = renderToStaticMarkup(<CloudStartView start={s} />);
    expect(html).toContain("fix the build");
    expect(html).toContain("cv-thinking");
    expect(html).not.toContain("acpmux-cloud-start__status");
    expect(html).not.toContain("acpmux-cloud-start__card");
    expect(html).not.toContain('data-step-id="machine"');
  }
});

test("the quiet line names the stage and counts its seconds, never a usual wait, and keeps Thinking as an arm", () => {
  const html = renderToStaticMarkup(<CloudStartView start={{ ...start, step: "machine" }} />);
  expect(html).toContain('data-stage="machine"');
  expect(html).toContain("Starting your Cloud machine");
  // No host start time: the clock still shows, counting from when the line first drew the stage.
  expect(html).toMatch(/<time class="cv-worked__time" data-stage-clock="true">0s<\/time>/);
  expect(html).not.toContain("usually");
  expect(html).not.toContain('data-step-id="machine"');
  // The copy stage, the hint arm's segments (machine done, copy current, agent next), and the arm
  // that keeps the line as it was.
  const hint = renderToStaticMarkup(<CloudStartView start={start} quietLook="hint" />);
  expect(hint).toContain("Copying your project");
  expect(hint.match(/data-step="(done|current|next)"/g)).toEqual([
    'data-step="done"',
    'data-step="current"',
    'data-step="next"',
  ]);
  const stacked = renderToStaticMarkup(<CloudStartView start={start} quietLook="stacked" />);
  expect(stacked).toContain("data-stage-clock");
  expect(stacked).not.toContain("usually");
  const thinking = renderToStaticMarkup(<CloudStartView start={start} quietLook="thinking" />);
  expect(thinking).toContain("cv-thinking");
  expect(thinking).not.toContain("acpmux-cloud-start__stage");
  // Once the agent has started the line is Thinking again.
  expect(renderToStaticMarkup(<CloudStartView start={{ ...start, initialized: true }} />)).not.toContain(
    "acpmux-cloud-start__stage",
  );
});

test("every arm shows the message and compact preparing status", () => {
  for (const name of ["chips", "rows", "steps"]) {
    arm(name);
    const html = renderToStaticMarkup(<CloudStartView start={start} showSteps />);
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
    root.render(<CloudStartView start={start} showSteps />);
  });
  const summary = container.querySelector<HTMLButtonElement>(".acpmux-cloud-start__summary");
  expect(summary?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => summary?.click());
  expect(summary?.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector('[data-step-id="machine"]')).toBeTruthy();
});

test("the steps arm keeps its legacy step list behind the disclosure", () => {
  arm("steps");
  const html = renderToStaticMarkup(<CloudStartView start={start} showSteps />);
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

test("a signed-out send is the first setup step, not a failure: the prompt, the steps, Sign in and ways on", () => {
  const variant = cloudStartGallery.variants["signed-out"]!;
  const html = renderToStaticMarkup(
    <CloudStartView {...variant.props} onRunHere={() => undefined} onDismiss={() => undefined} />,
  );
  expect(html).toContain(variant.props.start.task);
  expect(html).toContain('data-setup-step="account"');
  expect(html).toContain("acpmux-cloud-start__sign-in");
  expect(html).toContain("Sign in to run this chat on a Cloud machine.");
  expect(html).toContain("Your message sends by itself when you&#x27;re done.");
  // Step 1 of 3 is current, the plan and the model are named after it.
  expect(html).toContain('aria-label="Step 1 of 3"');
  expect(html).toMatch(/data-step="current" data-step-id="account"/);
  expect(html).toMatch(/data-step="next" data-step-id="plan"/);
  expect(html).toMatch(/data-step="next" data-step-id="model"/);
  // A way on besides Sign in, and no failed startup checklist or alert.
  expect(html).toContain('data-action="run-here"');
  expect(html).toContain('data-action="dismiss"');
  expect(html).not.toContain('role="alert"');
  expect(html).not.toContain("acpmux-cloud-start__checklist");
});

test("signed-out setup never falls back to the failed checklist or host CLI hint without a sign-in handler", () => {
  const html = renderToStaticMarkup(
    <CloudStartView
      start={{
        key: "signed-out",
        task: "Keep this prompt until sign-in finishes",
        state: "failed",
        code: "not_signed_in",
        message: "Sign in to use Cloud machines: run Sign In from the command palette, or `cmux cloud sign-in`.",
      }}
      showSteps
    />,
  );
  expect(html).toContain("Keep this prompt until sign-in finishes");
  expect(html).toContain('data-state="setup"');
  expect(html).toContain('data-action="sign-in"');
  expect(html).not.toContain('data-state="failed"');
  expect(html).not.toContain('role="alert"');
  expect(html).not.toContain("acpmux-cloud-start__checklist");
  expect(html).not.toContain("cmux cloud sign-in");
  expect(html).not.toContain("command palette");
});

test("each first-send gate draws the setup strip at its own step, earlier steps checked", () => {
  const task = "Run the sidebar tests and fix what fails.";
  const base = { key: "k", task, state: "failed" as const };
  const plan = renderToStaticMarkup(
    <CloudStartView start={{ ...base, code: "cloud_plan_required", refusedHere: true }} onRunHere={() => undefined} />,
  );
  expect(plan).toContain('data-setup-step="plan"');
  expect(plan).toMatch(/data-step="done" data-step-id="account"/);
  expect(plan).toMatch(/data-step="current" data-step-id="plan"/);
  expect(plan).toContain("Cloud needs a plan");
  expect(plan).not.toContain('role="alert"');
  const model = renderToStaticMarkup(
    <CloudStartView
      start={{ ...base, code: "cloud_setup_required", cloudSetup: { family: "claude" } }}
      onSetUp={() => undefined}
    />,
  );
  expect(model).toMatch(/data-step="done" data-step-id="plan"/);
  expect(model).toMatch(/data-step="current" data-step-id="model"/);
  expect(model).toContain('aria-label="Step 3 of 3"');
  // A plan refusal in a team is not a first-run step: its own notice, no strip.
  const team = renderToStaticMarkup(
    <CloudStartView
      start={{
        ...base,
        code: "cloud_plan_required",
        planTeam: { team: "Acme", switchTo: { id: "team_1", name: "Personal" } },
      }}
    />,
  );
  expect(team).not.toContain("acpmux-cloud-steps");
  // A start on its way draws no strip.
  expect(renderToStaticMarkup(<CloudStartView start={{ key: "k", task, state: "starting" }} />)).not.toContain(
    "acpmux-cloud-steps",
  );
});

test("a start waiting on its browser sign-in says so, not starting or Thinking", () => {
  const variant = cloudStartGallery.variants["signing-in"]!;
  for (const showSteps of [false, true]) {
    const html = renderToStaticMarkup(<CloudStartView {...variant.props} showSteps={showSteps} />);
    expect(html).toContain(variant.props.start.task);
    expect(html).toContain('data-signing-in="true"');
    expect(html).toContain("Waiting for you to sign in in your browser");
    expect(html).not.toContain("cv-thinking");
    expect(html).not.toContain("Preparing machine");
  }
  // While the browser is out the composer's prompt is held for the sign-in, so the waiting card offers no Run on
  // This Mac (it would switch to This Mac and send an empty composer) and no Not now; only the failed card does.
  const waiting = renderToStaticMarkup(
    <CloudStartView {...variant.props} onRunHere={() => undefined} onDismiss={() => undefined} />,
  );
  expect(waiting).toContain('data-setup-step="account"');
  expect(waiting).not.toContain('data-action="run-here"');
  expect(waiting).not.toContain('data-action="dismiss"');
  // Once signed in, the start reads as any start again.
  const { signingIn: _signingIn, ...started } = variant.props.start;
  const html = renderToStaticMarkup(<CloudStartView start={started} />);
  expect(html).toContain("cv-thinking");
  expect(html).not.toContain("data-signing-in");
});

test("a plan refusal shows the pricing card: cmux NEXT Plus, Pro and Max with Subscribe, Run on This Mac and Not Now", () => {
  const refusal = { ...start, state: "failed" as const, code: "cloud_plan_required" };
  const html = renderToStaticMarkup(
    <CloudStartView start={refusal} onRunHere={() => undefined} onDismiss={() => undefined} />,
  );
  expect(html).toContain("Cloud needs a plan");
  // Smallest first: Plus, then Pro, then Max.
  expect(html).toMatch(/data-plan="next_plus"[\s\S]*data-plan="next_pro"[\s\S]*data-plan="next_max"/);
  expect(html).toContain("cmux NEXT Plus");
  expect(html).toContain("$20 / month");
  expect(html).toContain("Machines up to 4 vCPU and 16 GB memory");
  expect(html).toContain("cmux NEXT Pro");
  expect(html).toContain("$50 / month");
  expect(html).toContain("Machines up to 8 vCPU and 32 GB memory");
  expect(html).toContain("cmux NEXT Max");
  expect(html).toContain("$200 / month");
  expect(html).toContain("Machines up to 32 vCPU and 64 GB memory");
  // The first plan's Subscribe leads, and only it.
  expect(html).toMatch(
    /data-action="subscribe" data-plan="next_plus"[^>]*data-role="default"[^>]*>Subscribe<\/button>/,
  );
  expect(html).toMatch(/data-action="subscribe" data-plan="next_pro"[^>]*>Subscribe<\/button>/);
  expect(html).toMatch(/data-action="subscribe" data-plan="next_max"[^>]*>Subscribe<\/button>/);
  expect(html).not.toMatch(/data-plan="next_pro"[^>]*data-role="default"/);
  expect(html).not.toMatch(/data-plan="next_max"[^>]*data-role="default"/);
  expect(html).not.toContain('data-plan="pro"');
  expect(html).toContain('data-action="run-here">Run on This Mac</button>');
  expect(html).toContain('data-action="dismiss">Not Now</button>');
  // Nothing started (the plan is checked before any machine): no startup card, no Upgrade of the classic plan.
  expect(html).not.toContain("acpmux-cloud-start__card");
  expect(html).not.toContain(">Upgrade</button>");
  const generic = renderToStaticMarkup(
    <CloudStartView start={{ ...refusal, code: "cloud_start_failed" }} onRunHere={() => undefined} />,
  );
  expect(generic).not.toContain('data-action="subscribe"');
  // Its way on is the start's own (cloudStartWayOn): Run on This Mac, filled where App passes no Retry.
  expect(generic).toContain('data-action="run-here" data-role="default">Run on This Mac</button>');
});

test("a plan refusal in a team says so, names the team and switches to the person's own; no Retry, no wait", async () => {
  const refusal: CloudStartProgress = {
    ...start,
    state: "failed",
    code: "cloud_plan_required",
    message: "Cloud machines need a Pro plan.",
    retryable: true,
    planTeam: { team: "cmux", switchTo: { id: "team_0123456789abcdef0123", name: "Personal" } },
  };
  const html = renderToStaticMarkup(
    <CloudStartView start={refusal} onSwitchTeam={() => undefined} onRetry={() => undefined} />,
  );
  expect(html).toContain("This team has no Cloud plan");
  expect(html).toContain("cmux is the team selected in the team menu.");
  expect(html).toContain('data-role="default" data-action="switch-team">Switch to Personal</button>');
  // The plans stay beside the switch, which leads: no Subscribe is filled.
  expect(html).toContain('data-action="subscribe" data-plan="next_pro"');
  expect(html).not.toMatch(/data-action="subscribe"[^>]*data-role="default"/);
  expect(html).not.toContain("acpmux-cloud-start__retry");
  expect(html).not.toContain("acpmux-cloud-start__card");
  expect(html).not.toContain("Cloud machines need a Pro plan.");
  // With no own team known, See plans leads.
  const plans = renderToStaticMarkup(
    <CloudStartView start={{ ...refusal, planTeam: { team: "cmux" } }} onSwitchTeam={() => undefined} />,
  );
  expect(plans).not.toContain("switch-team");
  expect(plans).toMatch(/data-action="subscribe" data-plan="next_plus"[^>]*data-role="default"/);
  // The click hands the team to the pane, which switches and sends again.
  const host = installDom();
  const picked: string[] = [];
  root = createRoot(host);
  await act(async () => root?.render(<CloudStartView start={refusal} onSwitchTeam={(team) => picked.push(team.id)} />));
  (host.querySelector('[data-action="switch-team"]') as HTMLButtonElement).click();
  expect(picked).toEqual(["team_0123456789abcdef0123"]);
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
  ).toBe("Copying the folder instead, because it is not a git repository · 1,204 of 8,310 files · 312 MB of 2.1 GB");
  expect(row({ state: "done", phase: "complete" })?.detail).toBeUndefined();
  expect(row({ state: "done", phase: "complete", fallback: "not_git" })?.detail).toBe(
    "Copying the folder instead, because it is not a git repository",
  );
  // A code the card has no words for still says it copies.
  expect(row({ state: "done", phase: "complete", fallback: "git_failed" })?.detail).toBe("Copying the folder instead");
});

test("the clone row says how many files a first pass left on this Mac, and nothing when none", () => {
  const row = (clone: NonNullable<CloudStartProgress["clone"]>) =>
    startupChecklist({ key: "k", task: "hi", state: "starting", hasRepository: true, clone }, undefined, 0, "en")[1];
  expect(row({ state: "done", phase: "complete", leftOnMac: 1204 })?.detail).toBe("1,204 files stayed on this Mac");
  expect(row({ state: "done", phase: "complete", leftOnMac: 1 })?.detail).toBe("1 file stayed on this Mac");
  expect(row({ state: "done", phase: "complete", fallback: "not_git", leftOnMac: 2 })?.detail).toBe(
    "Copying the folder instead, because it is not a git repository · 2 files stayed on this Mac",
  );
  expect(row({ state: "done", phase: "complete" })?.detail).toBeUndefined();
});

test("the opened checklist shows the files left on this Mac in the pane's words", async () => {
  const start: CloudStartProgress = {
    key: "k",
    task: "hi",
    state: "starting",
    hasRepository: true,
    clone: { state: "done", phase: "complete", leftOnMac: 1204 },
  };
  const host = installDom();
  root = createRoot(host);
  await act(async () => root?.render(<CloudStartView start={start} showSteps />));
  await act(async () => (host.querySelector(".acpmux-cloud-start__summary") as HTMLButtonElement).click());
  const detail = host.querySelector('[data-step-id="clone"] .acpmux-cloud-start__detail');
  expect(detail?.textContent).toBe("1,204 files stayed on this Mac");
  await act(async () =>
    root?.render(
      <CloudStartView start={{ ...start, clone: { state: "done", phase: "complete", leftOnMac: 1 } }} showSteps />,
    ),
  );
  expect(host.querySelector('[data-step-id="clone"] .acpmux-cloud-start__detail')?.textContent).toBe(
    "1 file stayed on this Mac",
  );
  await act(async () =>
    root?.render(<CloudStartView start={{ ...start, clone: { state: "done", phase: "complete" } }} showSteps />),
  );
  expect(host.querySelector('[data-step-id="clone"] .acpmux-cloud-start__detail')).toBeNull();
  expect(host.textContent).not.toContain("stayed on this Mac");
});

test("a copy's steps before its first file show, and keep saying why it copies", () => {
  const row = (clone: NonNullable<CloudStartProgress["clone"]>) =>
    startupChecklist({ key: "k", task: "hi", state: "starting", hasRepository: true, clone }, undefined, 0, "en")[1];
  // RED before: a pushed repository whose plan found no base showed only
  // "Copying the folder instead · 0 of 46,516 files" for minutes, with no reason and no movement.
  expect(
    row({ state: "running", phase: "prepare", fallback: "no_base", progress: { objects: 1, totalObjects: 4 } })?.detail,
  ).toBe("Copying the folder instead, because none of its commits are on GitHub · Checking files · 25%");
  expect(
    row({ state: "running", phase: "folders", fallback: "no_base", progress: { objects: 3, totalObjects: 4 } })?.detail,
  ).toBe("Copying the folder instead, because none of its commits are on GitHub · Making folders · 75%");
  expect(row({ state: "running", phase: "copy", fallback: "seed.needs_github" })?.detail).toBe(
    "Copying the folder instead, because the Cloud machine can't read the repository",
  );
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
    <CloudStartView start={{ key: "k", task: "hi", state: "starting", initialized: true }} showSteps />,
  );
  expect(html).toContain("Initialized session");
  expect(html).toContain('class="acpmux-cloud-start__status acpmux-cloud-start__status--ready"');
  expect(html).not.toContain('data-step-id="machine"');
});

test("startup durations use the supplied clock", () => {
  const rows = startupChecklist({ key: "k", task: "hi", state: "starting", machineStartedAt: 1_000 }, undefined, 3_500);
  expect(rows[0]?.duration).toBe("2s");
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

test("a failed setup keeps the environment target and opens its editor for repair", async () => {
  const opened: unknown[] = [];
  const failed: CloudStartProgress = {
    ...start,
    state: "failed",
    environment: "env_selected",
    environmentId: "env_resolved",
    setup: { state: "failed", status: "failed", hasScript: true, logTail: "setup exited with status 1" },
    step: undefined,
    retryable: true,
    message: "Environment setup failed.",
  };
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<CloudStartView start={failed} onOpenEnvironment={(options) => opened.push(options)} />);
  });
  const link = container.querySelector<HTMLButtonElement>("[data-step-id=setup] button");
  expect(link?.textContent).toBe("Edit cloud environment");
  expect(container.querySelector('[data-step-id="setup"]')?.textContent).toContain("setup exited with status 1");
  await act(async () => link?.click());
  expect(opened).toEqual([{ environmentId: "env_resolved", section: "script" }]);
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

const ask = {
  id: "ask-1",
  kind: "codexDevice" as const,
  title: "Sign in to Codex",
  lines: ["Enter this one-time code: WXYZ-1234"],
  buttons: [
    { id: "cancel", title: "Cancel", role: "cancel" as const },
    { id: "signedIn", title: "I signed in", role: "default" as const },
  ],
  code: "WXYZ-1234",
  link: { url: "https://auth.openai.com/codex/device", title: "Open sign-in" },
};

test("the host's question shows in the card with one filled button and its page as a link", () => {
  for (const name of ["inline", "sheet", "banner"]) {
    (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "cloud-start-ask": name };
    const html = renderToStaticMarkup(<CloudStartView start={{ ...start, ask }} onAnswer={async () => true} />);
    expect(html).toContain(`data-look="${name}"`);
    expect(html).toContain("Sign in to Codex");
    expect(html).toContain("WXYZ-1234");
    expect(html).toContain('href="https://auth.openai.com/codex/device"');
    expect(html.match(/data-role="default"/g)).toHaveLength(1);
    expect(html).toContain('data-open="true"');
  }
  expect(renderToStaticMarkup(<CloudStartView start={start} />)).not.toContain("acpmux-cloud-ask");
});

test("a click answers once with the ask's id and the button; a refused answer lets the buttons take another", async () => {
  const container = installDom();
  const answers: [string, string][] = [];
  let take = false;
  const onAnswer = async (id: string, button: string) => {
    answers.push([id, button]);
    return take;
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<CloudStartView start={{ ...start, ask }} onAnswer={onAnswer} />);
  });
  const yes = () => container.querySelector<HTMLButtonElement>('.acpmux-cloud-ask__button[data-role="default"]')!;
  await act(async () => yes().click());
  expect(answers).toEqual([["ask-1", "signedIn"]]);
  expect(yes().disabled).toBe(false);
  take = true;
  await act(async () => yes().click());
  expect(answers).toHaveLength(2);
  expect(yes().disabled).toBe(true);
  // The host takes the question away: the row closes and answers nothing more.
  await act(async () => root!.render(<CloudStartView start={start} onAnswer={onAnswer} />));
  const row = container.querySelector(".acpmux-cloud-ask-row");
  expect(row?.getAttribute("data-open")).toBe("false");
  expect(row?.getAttribute("aria-hidden")).toBe("true");
});

test("Retry shows only on a failure another try can help", async () => {
  const failed = { ...start, state: "failed" as const, message: "paint-dev didn't connect in time." };
  expect(renderToStaticMarkup(<CloudStartView start={failed} onRetry={() => undefined} />)).not.toContain(
    "acpmux-cloud-start__retry",
  );
  const container = installDom();
  let retried = 0;
  await act(async () => {
    root = createRoot(container);
    root.render(<CloudStartView start={{ ...failed, retryable: true }} onRetry={() => void retried++} />);
  });
  const retry = container.querySelector<HTMLButtonElement>(".acpmux-cloud-start__retry");
  expect(retry?.textContent).toBe("Retry");
  await act(async () => retry?.click());
  expect(retried).toBe(1);
});

test("a start connecting GitHub would fix offers Connect GitHub beside Retry, and no other failure does", async () => {
  const failed = { ...start, state: "failed" as const, retryable: true, message: "Connect GitHub to clone it." };
  const calls: string[] = [];
  let refuse = false;
  const github = createGitHubPicker(
    async (method) => {
      calls.push(method);
      if (refuse) throw new Error("GitHub isn't set up for this team.");
      return { opened: true };
    },
    () => () => undefined,
    () => false,
    () => () => undefined,
  );
  expect(
    renderToStaticMarkup(
      <CloudStartView
        start={{ ...failed, code: "cloud_start_failed" }}
        onRetry={() => undefined}
        githubStore={github}
      />,
    ),
  ).not.toContain('data-action="connect-github"');
  const container = installDom();
  let retried = 0;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <CloudStartView
        start={{ ...failed, code: "seed.needs_github" }}
        onRetry={() => void retried++}
        githubStore={github}
      />,
    );
  });
  const connect = container.querySelector<HTMLButtonElement>('[data-action="connect-github"]');
  expect(connect?.textContent).toBe("Connect GitHub");
  expect(connect?.getAttribute("data-role")).toBe("default");
  await act(async () => connect?.click());
  expect(calls).toEqual(["github.connect"]);
  const retry = container.querySelector<HTMLButtonElement>(".acpmux-cloud-start__retry");
  await act(async () => retry?.click());
  expect(retried).toBe(1);
  refuse = true;
  await act(async () => connect?.click());
  expect(container.querySelector("[data-connect-error]")?.textContent).toBe("GitHub isn't set up for this team.");
});

// #55104: the card's Connect names the start's repository, and the start goes again by itself once connected.
test("a needs-GitHub start connects for its repository and retries by itself once connected", async () => {
  const failed = {
    ...start,
    state: "failed" as const,
    retryable: true,
    code: "seed.needs_github",
    repository: "github:manaflow-ai/cmuxterm-hq",
    message: "Connect GitHub so Cloud can clone manaflow-ai/cmuxterm-hq, then retry.",
  };
  const asked: Array<[string, Record<string, unknown>]> = [];
  let reply: unknown = { opened: true };
  let changed: (() => void) | undefined;
  const github = createGitHubPicker(
    async (method, params) => {
      asked.push([method, params]);
      if (method === "github.status") return { state: "ready", repos_scope: "all" };
      if (method === "github.repos.list") return { repos: [] };
      return reply;
    },
    () => () => undefined,
    () => false,
    (run) => {
      changed = run;
      return () => undefined;
    },
  );
  const container = installDom();
  let retried = 0;
  await act(async () => {
    root = createRoot(container);
    root.render(<CloudStartView start={failed} onRetry={() => void retried++} githubStore={github} />);
  });
  const connect = container.querySelector<HTMLButtonElement>('[data-action="connect-github"]');
  // GitHub's page opened: nothing retries until the app says it finished the connection.
  await act(async () => connect?.click());
  expect(asked[0]).toEqual(["github.connect", { repo: "manaflow-ai/cmuxterm-hq" }]);
  expect(retried).toBe(0);
  await act(async () => changed?.());
  expect(retried).toBe(1);
  await act(async () => changed?.());
  expect(retried).toBe(1); // once per click
  // A connection already covers it: the start goes again at once, with no page.
  reply = { opened: false };
  await act(async () => connect?.click());
  expect(retried).toBe(2);
});

test("only a GitHub repository name reaches github.connect", () => {
  expect(githubFullName("manaflow-ai/cmuxterm-hq")).toBe("manaflow-ai/cmuxterm-hq");
  expect(githubFullName("github:acme/api")).toBe("acme/api");
  expect(githubFullName("https://github.com/acme/api.git")).toBe("acme/api");
  expect(githubFullName("git@github.com:acme/api.git")).toBe("acme/api");
  for (const bad of [undefined, "", "cmuxterm-hq", "https://gitlab.com/acme/api", "acme/api/x", "acme/..", "-acme/api"])
    expect(githubFullName(bad)).toBeUndefined();
});

test("a folder too big to copy offers each repository inside it and no folder, never Retry", async () => {
  const tooBig: CloudStartProgress = {
    ...start,
    state: "failed",
    code: "cloud_folder_too_big",
    refusedHere: true,
    message: "~/Projects is too big to copy to a Cloud machine.",
    tooBig: {
      folder: "~/Projects",
      repos: [
        { name: "cmux", path: "/Users/me/Projects/cmux" },
        { name: "work/api", path: "/Users/me/Projects/work/api" },
      ],
      more: false,
    },
  };
  const picked: string[] = [];
  let browsed = 0;
  let homes = 0;
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <CloudStartView
        start={tooBig}
        onRetry={() => undefined}
        onPickRepo={(path) => void picked.push(path)}
        onPickFolder={() => void browsed++}
        onStartWithoutFolder={() => void homes++}
      />,
    );
  });
  expect(container.querySelector(".acpmux-cloud-start__retry")).toBeNull();
  // The checklist stays shut: no step ran, and the card's actions stay in view.
  expect(container.querySelector(".acpmux-cloud-start__summary")?.getAttribute("aria-expanded")).not.toBe("true");
  const repos = [...container.querySelectorAll<HTMLButtonElement>("[data-repo]")];
  expect(repos.map((button) => button.textContent)).toEqual(["cmux", "work/api"]);
  expect(container.textContent).toContain("Pick a repo inside it");
  await act(async () => repos[1]!.click());
  expect(picked).toEqual(["/Users/me/Projects/work/api"]);
  // Every repository it holds is listed: no folder browse beside them.
  expect(container.querySelector('[data-action="pick-folder"]')).toBeNull();
  const noFolder = container.querySelector<HTMLButtonElement>('[data-action="no-folder"]');
  expect(noFolder?.textContent).toBe("Start without a folder");
  await act(async () => noFolder?.click());
  expect(homes).toBe(1);
  // No repository inside: Pick a folder leads, beside Start without a folder.
  await act(async () =>
    root!.render(
      <CloudStartView
        start={{ ...tooBig, tooBig: { folder: "~/Downloads", repos: [], more: false } }}
        onPickRepo={(path) => void picked.push(path)}
        onPickFolder={() => void browsed++}
        onStartWithoutFolder={() => void homes++}
      />,
    ),
  );
  expect(container.querySelector("[data-repo]")).toBeNull();
  const pick = container.querySelector<HTMLButtonElement>('[data-action="pick-folder"]');
  expect(pick?.textContent).toBe("Pick a folder");
  expect(pick?.getAttribute("data-role")).toBe("default");
  await act(async () => pick?.click());
  expect(browsed).toBe(1);
  // More repositories than the card lists: Pick a folder joins them.
  await act(async () =>
    root!.render(
      <CloudStartView
        start={{ ...tooBig, tooBig: { ...tooBig.tooBig!, more: true } }}
        onPickRepo={(path) => void picked.push(path)}
        onPickFolder={() => void browsed++}
      />,
    ),
  );
  expect(container.querySelectorAll("[data-repo]")).toHaveLength(2);
  expect(container.querySelector('[data-action="pick-folder"]')?.getAttribute("data-role")).toBeNull();
});

test("every failed start offers a way on in the card: the folder, a new Cloud chat, Retry or This Mac", async () => {
  const failed = (code: string, extra: Partial<CloudStartProgress> = {}): CloudStartProgress => ({
    ...start,
    state: "failed",
    code,
    message: "refused",
    ...extra,
  });
  const clicked: string[] = [];
  const handlers = {
    onRetry: () => void clicked.push("retry"),
    onPickFolder: () => void clicked.push("pick-folder"),
    onStartWithoutFolder: () => void clicked.push("no-folder"),
    onOpenNewCloudChat: () => void clicked.push("new-cloud-chat"),
    onRunHere: () => void clicked.push("run-here"),
    onDismiss: () => void clicked.push("dismiss"),
  };
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
  });
  const shown = async (progress: CloudStartProgress) => {
    await act(async () => root!.render(<CloudStartView start={progress} {...handlers} />));
    const buttons = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-cloud-start__way-on button")];
    return buttons.map((button) => `${button.dataset.action}${button.dataset.role === "default" ? "*" : ""}`);
  };
  for (const code of [
    "cloud_folder_missing",
    "cloud_folder_home",
    "cloud_folder_secret",
    "transport.path_outside_roots",
  ])
    expect(await shown(failed(code, { refusedHere: true })), code).toEqual(["pick-folder*", "no-folder"]);
  expect(await shown(failed("unavailable_now", { refusedHere: true }))).toEqual(["new-cloud-chat*"]);
  expect(await shown(failed("transport.gesture_required", { refusedHere: true }))).toEqual(["retry*"]);
  expect(await shown(failed("cloud_start_failed"))).toEqual(["retry*", "run-here"]);
  for (const code of [
    "cloud_disabled",
    "unavailable",
    "unsupported",
    "cloud_attachments",
    "sandbox_busy",
    "sandbox_spent",
  ])
    expect(await shown(failed(code)), code).toEqual(["run-here*", "dismiss"]);
  // A start with its own recovery words it itself: no second way on beside it.
  for (const progress of [
    failed("cloud_start_failed", { retryable: true }),
    failed("not_signed_in"),
    failed("cloud_plan_required"),
    failed("cloud_spend_cap"),
    { ...start },
  ])
    expect(await shown(progress), progress.code ?? "starting").toEqual([]);
  // Each button runs its own handler.
  await shown(failed("cloud_start_failed"));
  for (const button of container.querySelectorAll<HTMLButtonElement>(".acpmux-cloud-start__way-on button"))
    await act(async () => button.click());
  expect(clicked).toEqual(["retry", "run-here"]);
  // A handler App does not pass draws no button.
  await act(async () =>
    root!.render(
      <CloudStartView start={failed("unavailable_now", { refusedHere: true })} onRunHere={() => undefined} />,
    ),
  );
  expect(container.querySelector(".acpmux-cloud-start__way-on")).toBeNull();
});

test("the connection card offers the preserved send on This Mac", async () => {
  const container = installDom();
  root = createRoot(container);
  const task = "keep this prompt";
  const local: string[] = [];
  const connect: string[] = [];
  await act(async () =>
    root!.render(
      <CloudStartView
        start={{ key: "k", task, state: "failed", code: "cloud_setup_required", cloudSetup: { family: "codex" } }}
        onRunHere={() => local.push(task)}
        onSetUp={(action) => connect.push(action)}
        onSetUpDismiss={() => undefined}
      />,
    ),
  );
  const buttons = [...container.querySelectorAll("button")];
  expect(buttons.map((button) => button.dataset.action)).toEqual(["addKey", "run-here", "dismiss"]);
  expect(buttons[1]?.textContent).toBe("Run on This Mac");
  expect(container.textContent).toContain(task);
  await act(async () => buttons[1]!.click());
  expect(local).toEqual([task]);
  expect(connect).toEqual([]);
});
