// l10n-allow-file: test fixture documents and links, not shipped UI.
// Session Info's Outputs (Claude Code desktop's): each artifact the chat produced by its title with an
// Artifact tag, opening in the side panel beside the chat; the gallery; the files, each opening its
// diff. Never the links its replies gave: those are not things it made. Every row opens what it names.
// Every section in view (`setSessionInfoMore(true)`): the panel's compact default view is
// session-info-compact-default.test.tsx's.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { Artifact } from "../src/agent-session/acpmux/conversation/artifactPreview";
import { renderId } from "../src/agent-session/acpmux/conversation/renderCall";
import { translate } from "../src/agent-session/acpmux/i18n";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  DEFAULT_SECTIONS,
  resetSessionInfoState,
  setSessionInfoMore,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { OutputsSection } from "../src/agent-session/acpmux/session-info/OutputsSection";
import {
  OUTPUTS_SHOWN,
  outputArtifacts,
  outputLinks,
} from "../src/agent-session/acpmux/session-info/outputsSectionModel";
import { SummaryBody } from "../src/agent-session/acpmux/summary/SummaryBody";
import type { SessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, assistant, chat, tool } from "../src/gallery/fixtures/acpmux";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { resetLinkStore } from "../src/agent-session/acpmux/chips/linkStore";
import { until } from "./support/until";
import { settleReact } from "./support/domTeardown";

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
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => {
  resetSessionInfoState();
  setSessionInfoMore(true);
});

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
});

const render = (input: Record<string, unknown>) =>
  tool("mcp__cmux__render", "other", "completed", { inputSummary: JSON.stringify(input), output: '{"rendered":true}' });
const LEDGER = "<!doctype html><title>Leo's Asks Ledger</title><h1>Asks</h1>";
const PLAN = "```markdown\n# Session Info rollout\n\n- Context\n```\n";

const rows = [
  activity([render({ html: LEDGER })], 4),
  // An update of the ledger's card: one row, its latest page.
  activity(
    [render({ html: `${LEDGER}<p>v2</p>`, id: renderId(LEDGER) }), render({ title: "Chart", html: "<svg></svg>" })],
    3,
  ),
  assistant(`Here is the plan:\n\n${PLAN}\nSee https://cmux.com/docs/session-info.`, 2),
  // The same document again, and one still streaming: neither is listed twice or early.
  assistant(`Again:\n\n${PLAN}`, 1),
  assistant("```html\n<title>Draft</title>\n```\n", 0, { streaming: true }),
];

test("the chat's artifacts: each render card once by its title, then each document its replies drew, once", () => {
  const found = outputArtifacts(rows);
  expect(found.map((item) => [item.title, item.artifact.kind])).toEqual([
    ["Leo's Asks Ledger", "html"],
    ["Chart", "html"],
    ["Session Info rollout", "markdown"],
  ]);
  // A render opens as its card, so the side panel steps through its pages.
  expect(found[0]!.artifact.render).toBeDefined();
  expect(found[2]!.artifact.render).toBeUndefined();
});

test("every Outputs row opens what it names: artifacts in the side panel, made files through the host; no code edits, no links", async () => {
  const container = installDom();
  const opened: Artifact[] = [];
  const host: Array<[string, Record<string, unknown>]> = [];
  setChipHost(async (method, params) => void host.push([method, params]));
  const base = chat(rows);
  // A shell command made the PDF; the reply links it (the Codex app's rule: a linked document).
  const made = [...rows, assistant("I created the PDF at [hello-world.pdf](/tmp/hello-pdf/hello-world.pdf).", 9)];
  try {
    await act(async () => {
      root = createRoot(container);
      root.render(
        <SessionInfo
          summary={base.summary}
          machineName="cosmic-gray"
          rows={made}
          documents={outputArtifacts(made)}
          onOpenDocument={(artifact) => opened.push(artifact)}
          sections={{ ...DEFAULT_SECTIONS, outputs: true }}
        />,
      );
    });
    const outputs = container.querySelector<HTMLElement>('ul[data-section="outputs"]')!;
    const buttons = [...outputs.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row")];
    const artifactTag = translate("sessionInfo.outputs.artifact");
    expect(buttons.map((button) => button.textContent)).toEqual([
      `Leo's Asks Ledger${artifactTag}`,
      `Chart${artifactTag}`,
      `Session Info rollout${artifactTag}`,
      "hello-world.pdf/tmp/hello-pdf",
    ]);
    await act(async () => buttons[0]!.click());
    await act(async () => buttons[2]!.click());
    expect(opened.map((artifact) => artifact.kind)).toEqual(["html", "markdown"]);
    expect(opened[0]!.code).toContain("v2");
    await act(async () => buttons[3]!.click());
    expect(host.filter(([method]) => method === "link.openPath")).toEqual([
      ["link.openPath", { path: "/tmp/hello-pdf/hello-world.pdf" }],
    ]);
    // The links the replies gave are not outputs.
    expect(outputs.querySelector("a")).toBeNull();
  } finally {
    setChipHost(undefined);
  }
});

test("a file the agent made, then deleted, drops off Outputs", async () => {
  const container = installDom();
  resetLinkStore();
  const inspected: string[] = [];
  setChipHost(async (method, params) => {
    if (method !== "link.inspect") return undefined;
    const asked = (params.paths ?? []) as string[];
    inspected.push(...asked);
    return {
      paths: Object.fromEntries(
        asked.map((path) => [path, { place: path.endsWith("gone.pdf") ? "missing" : "root", folder: false }]),
      ),
    };
  });
  const base = chat([]);
  try {
    await act(async () => {
      root = createRoot(container);
      root.render(
        <SessionInfo
          summary={base.summary}
          rows={[assistant("Made `/tmp/kept.pdf` and `/tmp/gone.pdf`.", 1)]}
          sections={{ ...DEFAULT_SECTIONS, outputs: true }}
        />,
      );
    });
    // The host answers once the batch flushes; the act it is asked in returns only after a task
    // turn, when its answer is in the store and drawn.
    await until(
      () => inspected.includes("/tmp/gone.pdf"),
      () => act(async () => {}),
    );
    const outputs = container.querySelector<HTMLElement>('ul[data-section="outputs"]')!;
    expect(outputs.textContent).toContain("kept.pdf");
    expect(outputs.textContent).not.toContain("gone.pdf");
  } finally {
    setChipHost(undefined);
    resetLinkStore();
  }
});

test("a chat on another machine lists its made files as plain rows", async () => {
  const container = installDom();
  const base = chat([]);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfo
        summary={{ ...base.summary!, peer: "build-box" }}
        rows={[assistant("Report: [q3.xlsx](/home/me/q3.xlsx)", 1)]}
        sections={{ ...DEFAULT_SECTIONS, outputs: true }}
      />,
    );
  });
  const outputs = container.querySelector<HTMLElement>('ul[data-section="outputs"]')!;
  expect(outputs.querySelector("button")).toBeNull();
  const row = outputs.querySelector<HTMLElement>(".acpmux-session-info-row")!;
  expect(row.tagName).toBe("DIV");
  expect(row.textContent).toContain("q3.xlsx");
});

test("without a side panel (Quick Chat) the artifacts are not listed", async () => {
  const container = installDom();
  const base = chat(rows);
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo summary={base.summary} rows={rows} documents={outputArtifacts(rows)} />);
  });
  expect(container.querySelector('ul[data-section="outputs"]')).toBeNull();
});

test("SummaryBody does not re-add checkpoint files outside the project", async () => {
  const container = installDom();
  const summary: SessionSummary = {
    cwd: "/work/project",
    scheduled: [],
    pullRequests: [],
    outputs: [],
    subagents: [],
    sources: [],
    backgroundTasks: [],
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SummaryBody
        summary={summary}
        changes={{
          additions: 2,
          deletions: 0,
          files: [{ path: "/tmp/m1076.txt", displayPath: "m1076.txt", additions: 2, deletions: 0, created: true }],
        }}
        onOpenChanges={() => undefined}
      />,
    );
  });
  expect(container.textContent).not.toContain("m1076.txt");
});

// Leo (ask-fd0730a919): show more / show less per thing, Changes, Outputs, subagents, the whole row
// clickable with no pill, as Claude Code desktop's.
test("five Outputs show, then a whole-row Show 3 more opens the rest and Show less folds them again", async () => {
  const container = installDom();
  const files = Array.from({ length: 8 }, (_, index) => ({
    path: `/src/f${index}.ts`,
    displayPath: `src/f${index}.ts`,
    edits: [],
    additions: 1,
    deletions: 0,
    created: false,
  }));
  await act(async () => {
    root = createRoot(container);
    root.render(<OutputsSection files={files} artifacts={0} />);
  });
  const shown = () => container.querySelectorAll('ul[data-section="outputs"] > li').length;
  const fold = () => container.querySelector<HTMLButtonElement>("button.acpmux-session-info-fold");
  expect(shown()).toBe(OUTPUTS_SHOWN);
  expect(fold()?.textContent).toBe(translate("sessionInfo.list.showMore", { n: 3 }));
  expect(fold()?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => fold()!.click());
  expect(shown()).toBe(8);
  expect(fold()?.textContent).toBe(translate("sessionInfo.outputs.showLess"));
  await act(async () => fold()!.click());
  expect(shown()).toBe(OUTPUTS_SHOWN);

  // Six or fewer: no fold at all ("Show 1 more" would cost the row it saves).
  await act(async () => root!.render(<OutputsSection files={files.slice(0, OUTPUTS_SHOWN + 1)} artifacts={0} />));
  expect(shown()).toBe(OUTPUTS_SHOWN + 1);
  expect(fold()).toBeNull();
});

// Outputs lists what the chat made, never the links its replies gave (Lucas, 2026-11-05: "outputs
// should be images, files, ect generate directly through that chat").
test("a chat whose replies only gave links has no Outputs", async () => {
  const container = installDom();
  const base = chat(rows);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfo
        summary={base.summary}
        rows={rows}
        made={{ outputs: [], pullRequests: [], scheduled: [] }}
        sections={{ ...DEFAULT_SECTIONS, outputs: true }}
      />,
    );
  });
  expect(outputLinks(rows).length).toBeGreaterThan(0);
  expect(container.querySelector('[data-section="outputs"]')).toBeNull();
});
