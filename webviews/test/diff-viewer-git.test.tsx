// l10n-allow-file: test fixture file names and commit messages, not shipped UI.
// The diff viewer stages and commits (cx-ueuc8, dogfood run hq #1893): the chat header's ± opens it,
// and it had no Stage, Commit or Push. On a host that serves `cmux.diff.git.*` it now shows the
// changes view's own Commit and Push (useGitWrite, GitActions) and a file header's Stage, in the
// viewer's language, and each runs as the host's op; the host picks the repository. From a chat
// the ± opens Branch, so there a file with work-tree changes gets Stage too (cx-4ukqc, run 2).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { currentLanguage, setPaneLanguage } from "../src/agent-session/acpmux/i18n";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// diffGitSource installs the viewer's git strings over the agent pane's string tables and switches
// the pane's language to the viewer's (diff-viewer/git.ts). Both are process-wide, and bun runs
// every file in one process, so they are saved here, before anything changes them, and restored
// after: left as they are, later files read a table with only the git strings, in Japanese, and
// render raw keys.
const paneLanguageBefore = currentLanguage();
const paneStringsBefore = globalThis.__cmuxPaneStrings;

Object.defineProperty(dom.window.navigator, "languages", { configurable: true, get: () => ["ja"] });

const { act, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { loadDiffViewerLabels } = await import("../src/labels");
await loadDiffViewerLabels("ja");
const { diffGitSource, useDiffStageAction } = await import("../src/diff-viewer/git");
const { GitToolbarButtons, GitWriteBar } = await import("../src/agent-session/acpmux/changes/GitActions");
const { useGitWrite } = await import("../src/agent-session/acpmux/changes/useGitWrite");
const { FileHeader } = await import("../src/diff-viewer/FileHeader");
const { createDiffViewerLabelResolver } = await import("../src/labels");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  globalThis.__cmuxPaneStrings = paneStringsBefore;
  setPaneLanguage(paneLanguageBefore);
});

const HEAD = "0123456789abcdef0123456789abcdef01234567";
const OPS = [
  "cmux.diff.git.status",
  "cmux.diff.git.diff",
  "cmux.diff.git.commit",
  "cmux.diff.git.push",
  "cmux.diff.git.stage",
  "cmux.diff.git.unstage",
];
const calls: [string, unknown][] = [];
const page = {
  call: async (op: string, params: unknown) => {
    calls.push([op, params]);
    if (op === "cmux.diff.git.status")
      return { head: HEAD, branch: "main", upstream: "origin/main", detached: false, ahead: 0 };
    if (op === "cmux.diff.git.diff" && (params as { scope?: string }).scope === "unstaged")
      return { scope: "unstaged", files: [{ path: "src/upload.ts", additions: 1, deletions: 1 }] };
    if (op === "cmux.diff.git.commit")
      return { result: { commit: HEAD, summary: "Retry the upload", filesChanged: 1 }, replayed: false };
    return { ok: true };
  },
  subscribe: async () => () => {},
};
const buttons = () => [...dom.window.document.querySelectorAll("button")];
const button = (text: string) => buttons().find((element) => element.textContent?.trim() === text);

test("a host without the git ops gets no git controls", () => {
  expect(diffGitSource(page as never, ["cmux.diff.prefs.get"])).toBeUndefined();
  expect(diffGitSource(null, OPS)).toBeUndefined();
});

test("the viewer commits through the host and stages a file from its header, in its language", async () => {
  const source = diffGitSource(page as never, OPS)!;
  const staged: string[] = [];
  function Viewer() {
    const [open, setOpen] = useState(false);
    const git = useGitWrite(source, () => {});
    const stage = useDiffStageAction(source, { kind: "unstaged", repoRoot: "/r" }, 0, {
      staged: () => staged.push("refreshed"),
      failed: () => {},
    });
    return (
      <div className="diff-git">
        <GitToolbarButtons git={git} formOpen={open} onToggleForm={() => setOpen((value) => !value)} />
        <GitWriteBar git={git} formOpen={open} onCloseForm={() => setOpen(false)} />
        <FileHeader
          item={{ id: "f1", fileDiff: { name: "src/upload.ts", hunks: [] } } as never}
          label={createDiffViewerLabelResolver(undefined, { language: "ja" })}
          onLoadDiff={() => {}}
          onToggleCollapsed={() => {}}
          onToggleViewed={() => {}}
          stage={stage}
          viewedState="unviewed"
        />
      </div>
    );
  }
  await act(async () => root.render(<Viewer />));
  await act(async () => {});
  expect(calls.map(([op]) => op)).toContain("cmux.diff.git.status");

  // Stage, in Japanese, stages that file through the host.
  await act(async () => button("ステージ")!.click());
  expect(calls).toContainEqual(["cmux.diff.git.stage", { paths: ["src/upload.ts"] }]);
  expect(staged).toEqual(["refreshed"]);

  // Commit opens the changes view's form; its Commit sends the message.
  await act(async () =>
    buttons()
      .find((element) => element.dataset.tool === "commit")!
      .click(),
  );
  const message = dom.window.document.querySelector<HTMLTextAreaElement>(".acpmux-git-message")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(message, "Retry the upload");
    message.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => dom.window.document.querySelector<HTMLButtonElement>(".acpmux-git-primary")!.click());
  const commit = calls.find(([op]) => op === "cmux.diff.git.commit");
  expect(commit?.[1]).toMatchObject({ message: "Retry the upload", expected_head: HEAD });
});

test("in Branch, as the chat's ± opens it, a file with work-tree changes gets Stage and a committed one doesn't", async () => {
  const source = diffGitSource(page as never, OPS)!;
  const label = createDiffViewerLabelResolver(undefined, { language: "ja" });
  function Header({ name }: { name: string }) {
    const stage = useDiffStageAction(source, { kind: "branch", repoRoot: "/r", baseRef: "main" }, 0, {
      staged: () => {},
      failed: () => {},
    });
    return (
      <FileHeader
        item={{ id: name, fileDiff: { name, hunks: [] } } as never}
        label={label}
        onLoadDiff={() => {}}
        onToggleCollapsed={() => {}}
        onToggleViewed={() => {}}
        stage={stage}
        viewedState="unviewed"
      />
    );
  }
  await act(async () =>
    root.render(
      <div>
        <Header name="src/upload.ts" />
        <Header name="docs/committed.md" />
      </div>,
    ),
  );
  await act(async () => {});
  const stages = buttons().filter((element) => element.textContent?.trim() === "ステージ");
  expect(stages.length).toBe(1);
  calls.length = 0;
  await act(async () => stages[0]!.click());
  expect(calls).toContainEqual(["cmux.diff.git.stage", { paths: ["src/upload.ts"] }]);
});
