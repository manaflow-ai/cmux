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
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
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

test("a signed-out failure keeps the prompt card and offers inline sign-in", () => {
  const variant = cloudStartGallery.variants["signed-out"]!;
  const html = renderToStaticMarkup(<CloudStartView {...variant.props} />);
  expect(html).toContain(variant.props.start.task);
  expect(html).toContain('class="acpmux-cloud-start__sign-in"');
  expect(html).toContain("Sign in to use Cloud.");
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
  // Once signed in, the start reads as any start again.
  const { signingIn: _signingIn, ...started } = variant.props.start;
  const html = renderToStaticMarkup(<CloudStartView start={started} />);
  expect(html).toContain("cv-thinking");
  expect(html).not.toContain("data-signing-in");
});

test("a plan refusal offers Upgrade, Run on This Mac and Not Now; other failures offer none", () => {
  const refusal = { ...start, state: "failed" as const, code: "cloud_plan_required" };
  const html = renderToStaticMarkup(
    <CloudStartView
      start={refusal}
      onUpgrade={() => undefined}
      onRunHere={() => undefined}
      onDismiss={() => undefined}
    />,
  );
  expect(html).toContain('data-role="default">Upgrade</button>');
  expect(html).toContain(">Run on This Mac</button>");
  expect(html).toContain(">Not Now</button>");
  // A refusal by policy keeps the checklist shut, so its actions stay in view in a short pane.
  expect(html).toContain('aria-expanded="false"');
  const generic = renderToStaticMarkup(
    <CloudStartView
      start={{ ...refusal, code: "cloud_start_failed" }}
      onUpgrade={() => undefined}
      onRunHere={() => undefined}
    />,
  );
  expect(generic).not.toContain(">Upgrade</button>");
  expect(generic).not.toContain(">Run on This Mac</button>");
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
    <CloudStartView
      start={refusal}
      onSwitchTeam={() => undefined}
      onUpgrade={() => undefined}
      onRetry={() => undefined}
    />,
  );
  expect(html).toContain("This team has no Cloud plan");
  expect(html).toContain("cmux is the team selected in the team menu.");
  expect(html).toContain('data-role="default" data-action="switch-team">Switch to Personal</button>');
  expect(html).toContain('data-action="see-plans">See plans</button>');
  expect(html).not.toContain("acpmux-cloud-start__retry");
  expect(html).not.toContain("acpmux-cloud-start__card");
  expect(html).not.toContain("Cloud machines need a Pro plan.");
  // With no own team known, See plans leads.
  const plans = renderToStaticMarkup(
    <CloudStartView
      start={{ ...refusal, planTeam: { team: "cmux" } }}
      onSwitchTeam={() => undefined}
      onUpgrade={() => undefined}
    />,
  );
  expect(plans).not.toContain("switch-team");
  expect(plans).toContain('data-role="default" data-action="see-plans"');
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
    <CloudStartView start={{ key: "k", task: "hi", state: "starting", initialized: true }} showSteps />,
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
