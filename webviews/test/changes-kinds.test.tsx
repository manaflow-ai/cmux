// The chat's Changes view reads a change the way the diff viewer and the pull request card do
// (Leo 2026-10-21, "this is pretty uninformative compared to claude... no tests, some other
// useful metadata"): files in kind order, a kind label on each file that isn't code, a quiet
// line when code changed and no test did, and generated files folded until opened.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../src/agent-session/acpmux/DiffPanel");
const { toolFiles } = await import("../src/agent-session/acpmux/diff");
const { orderByKind } = await import("../src/fileKinds");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// One tool call per path, each changing the file's only line.
const turn = (paths: string[]) =>
  toolFiles(
    paths.map((path, index) => ({
      id: `edit-${index}`,
      kind: "edit",
      title: `Edit ${path}`,
      status: "completed",
      diffs: [{ path, oldText: "before\n", newText: "after\n" }],
    })) as never,
  );

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

/// `folder`: the chat's folder, which App.tsx passes as `root`; null renders with none known.
async function render(files: ReturnType<typeof turn>, folder: string | null = "/repo") {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(<DiffPanel files={files} {...(folder === null ? {} : { root: folder })} onClose={() => {}} />),
  );
  await settle();
  const blocks = () => [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")];
  return {
    container,
    names: () => blocks().map((block) => block.querySelector(".acpmux-fh-name")?.textContent ?? ""),
    kinds: () => blocks().map((block) => block.querySelector(".acpmux-fh-kind")?.textContent ?? ""),
    folded: () =>
      blocks()
        .filter((block) => block.dataset.collapsed !== undefined)
        .map((block) => block.dataset.path),
    noTests: () => container.querySelector(".acpmux-diff-no-tests")?.textContent,
    unmount: () => act(async () => root.unmount()),
  };
}

test("files read in kind order, code first, each kind in the order the turn changed it", async () => {
  const view = await render(
    turn(["/repo/bun.lock", "/repo/README.md", "/repo/src/b.ts", "/repo/test/a.test.ts", "/repo/src/a.ts"]),
  );
  try {
    expect(view.names()).toEqual(["src/b.ts", "src/a.ts", "test/a.test.ts", "README.md", "bun.lock"]);
    // The diff viewer's names for the kinds; code needs none.
    expect(view.kinds()).toEqual(["", "", "Tests", "Docs", "Generated"]);
    // A test changed, so nothing is missing.
    expect(view.noTests()).toBeUndefined();
    // A lockfile starts folded; the code, test and doc beside it start open.
    expect(view.folded()).toEqual(["/repo/bun.lock"]);
  } finally {
    await view.unmount();
  }
});

test("code changed with no test says so, quietly, above the files", async () => {
  const view = await render(turn(["/repo/docs/guide.md", "/repo/src/a.ts"]));
  try {
    expect(view.names()).toEqual(["src/a.ts", "docs/guide.md"]);
    expect(view.noTests()).toBe("Code changed with no test.");
  } finally {
    await view.unmount();
  }
});

test("a turn of docs or generated files alone is not missing a test", async () => {
  const view = await render(turn(["/repo/README.md", "/repo/bun.lock"]));
  try {
    expect(view.noTests()).toBeUndefined();
  } finally {
    await view.unmount();
  }
});

test("a file's kind is read from its whole path, not the folder the turn's files share", async () => {
  // Both files sit under tests/, which their shown names drop.
  const view = await render(turn(["/repo/tests/helpers.py", "/repo/tests/fixtures/answer.json"]));
  try {
    expect(view.names()).toEqual(["helpers.py", "fixtures/answer.json"]);
    expect(view.kinds()).toEqual(["Tests", "Mocks"]);
    expect(view.noTests()).toBeUndefined();
  } finally {
    await view.unmount();
  }
});

test("a generated file the reader opens stays open", async () => {
  const view = await render(turn(["/repo/src/a.ts", "/repo/package-lock.json"]));
  try {
    expect(view.folded()).toEqual(["/repo/package-lock.json"]);
    const lockName = [...view.container.querySelectorAll<HTMLButtonElement>(".acpmux-fh-name")].find((button) =>
      button.textContent?.includes("package-lock.json"),
    )!;
    await act(async () => lockName.click());
    await settle();
    expect(view.folded()).toEqual([]);
  } finally {
    await view.unmount();
  }
});

test("a git scope reads each file's kind from the repository's top, not the folders above it", async () => {
  const patch = (path: string) =>
    `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-one\n+two\n`;
  const listed = (path: string) => ({ path, status: "modified", additions: 1, deletions: 1, patch: patch(path) });
  // The repository sits in a folder named `tests`; its files are still code and docs.
  const source = {
    diff: async () => ({ root: "/home/me/tests/repo", files: [listed("README.md"), listed("src/a.ts")] }),
  };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
  await settle();
  const unstaged = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (item) => item.textContent === "Unstaged",
  )!;
  await act(async () => unstaged.click());
  await settle();
  try {
    const blocks = [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")];
    expect(blocks.map((block) => block.querySelector(".acpmux-fh-name")?.textContent)).toEqual([
      "src/a.ts",
      "README.md",
    ]);
    expect(blocks.map((block) => block.querySelector(".acpmux-fh-kind")?.textContent ?? "")).toEqual(["", "Docs"]);
    expect(container.querySelector(".acpmux-diff-no-tests")?.textContent).toBe("Code changed with no test.");
  } finally {
    await act(async () => root.unmount());
  }
});

test("orderByKind sorts by kind and hands back a list of one kind untouched", () => {
  const items = ["src/a.ts", "src/b.ts"];
  expect(orderByKind(items, (path) => path)).toBe(items);
  expect(orderByKind(["yarn.lock", "README.md", "src/a.ts"], (path) => path)).toEqual([
    "src/a.ts",
    "README.md",
    "yarn.lock",
  ]);
});

// A folder above the project never names a Last turn file's kind (review of #24188): the path is
// read from the chat's folder, and a file outside it by its name alone.
test("a Last turn file's kind ignores the folders above the chat's folder", async () => {
  const { kindPath } = await import("../src/agent-session/acpmux/DiffPanel");
  const { fileKind } = await import("../src/fileKinds");
  const file = (path: string) => ({
    path,
    displayPath: path.split("/").pop()!,
    edits: [],
    additions: 1,
    deletions: 0,
    created: false,
  });
  const kind = (path: string, root?: string) => fileKind(kindPath("lastTurn", file(path), root));
  expect(kind("/home/me/tests/repo/src/app.ts", "/home/me/tests/repo")).toBe("code");
  expect(kind("/home/me/docs/repo/src/app.ts", "/home/me/docs/repo/")).toBe("code");
  expect(kind("/home/me/repo/tests/helpers.py", "/home/me/repo")).toBe("tests");
  expect(kind("/home/me/generated/repo/src/app.ts")).toBe("code");
  expect(kind("/tmp/tests/scratch.ts", "/home/me/repo")).toBe("code");
  expect(kind("/home/me/repo/package-lock.json", "/home/me/repo")).toBe("generated");
  // A path that leaves the chat's folder is read by its name.
  expect(kind("../generated/scratch.ts", "/home/me/repo")).toBe("code");
  expect(kind("tests/helpers.py", "/home/me/repo")).toBe("tests");
  // Either spelling acpmux recorded: /tmp is /private/tmp.
  const aliased = { ...file("/tmp/repo/tests/helpers.py"), canonical: "/private/tmp/repo/tests/helpers.py" };
  expect(fileKind(kindPath("lastTurn", aliased, "/private/tmp/repo"))).toBe("tests");
});

test("with no folder known, a Last turn file is read by its name", async () => {
  const view = await render(turn(["/repo/tests/helpers.py", "/repo/src/a.ts"]), null);
  try {
    expect(view.kinds()).toEqual(["", ""]);
    expect(view.noTests()).toBe("Code changed with no test.");
  } finally {
    await view.unmount();
  }
});

test("with no folder known, a relative Last turn path is read by its name too", async () => {
  const view = await render(turn(["tests/helpers.py", "src/a.ts"]), null);
  try {
    expect(view.kinds()).toEqual(["", ""]);
    expect(view.noTests()).toBe("Code changed with no test.");
  } finally {
    await view.unmount();
  }
});

test("an incomplete checkpoint marks the tool-call view partial, so it never says no test changed", async () => {
  const { turnDisplay } = await import("../src/agent-session/acpmux/changes/turnCheckpoint");
  const { translatorFor } = await import("../src/agent-session/acpmux/i18n");
  const display = turnDisplay(
    translatorFor("en"),
    turn(["/repo/src/a.ts"]),
    { state: "incomplete", checkpointId: "c1" },
    false,
  );
  expect(display.source).toBe("tools");
  expect(display.partial).toBe(true);
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(<DiffPanel files={display.files} turn={display} root="/repo" onClose={() => {}} />),
    );
    await settle();
    expect(container.querySelector(".acpmux-diff-no-tests")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("opening the view on a folded generated file unfolds it", async () => {
  const files = turn(["/repo/src/a.ts", "/repo/bun.lock"]);
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const folded = () =>
    [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")]
      .filter((block) => block.dataset.collapsed !== undefined)
      .map((block) => block.dataset.path);
  try {
    await act(async () => root.render(<DiffPanel files={files} root="/repo" onClose={() => {}} />));
    await settle();
    expect(folded()).toEqual(["/repo/bun.lock"]);
    await act(async () =>
      root.render(<DiffPanel files={files} root="/repo" initialPath="/repo/bun.lock" onClose={() => {}} />),
    );
    await settle();
    expect(folded()).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a git scope that left files out never says no test changed", async () => {
  const patch = (path: string) =>
    `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-one\n+two\n`;
  const listed = (path: string) => ({ path, status: "modified", additions: 1, deletions: 1, patch: patch(path) });
  for (const omitted of [{ files_omitted: 2 }, { untracked_skipped: 1 }]) {
    // The omitted file may be the test.
    const source = { diff: async () => ({ root: "/repo", files: [listed("src/a.ts")], ...omitted }) };
    const container = dom.window.document.getElementById("root")!;
    const root = createRoot(container);
    await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
    await settle();
    const unstaged = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
      (item) => item.textContent === "Unstaged",
    )!;
    await act(async () => unstaged.click());
    await settle();
    try {
      expect(container.querySelectorAll(".acpmux-diff-file").length).toBe(1);
      expect(container.querySelector(".acpmux-diff-no-tests")).toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("a partial checkpoint for Last turn never says no test changed", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(
        <DiffPanel
          files={turn(["/repo/src/a.ts"])}
          turn={{ source: "checkpoint", partial: true }}
          root="/repo"
          onClose={() => {}}
        />,
      ),
    );
    await settle();
    expect(container.querySelector(".acpmux-diff-no-tests")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a partial checkpoint with Keep or Undo choices pending never says no test changed", async () => {
  const { readTurnCheckpoint, turnDisplay } = await import("../src/agent-session/acpmux/changes/turnCheckpoint");
  const { translatorFor } = await import("../src/agent-session/acpmux/i18n");
  const patch = "diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n-before\n+after\n";
  const listed = { path: "src/a.ts", status: "modified", additions: 1, deletions: 1, patch };
  for (const omitted of [{ files_omitted: 1 }, { untracked_skipped: 1 }]) {
    const load = readTurnCheckpoint({
      checkpoint_id: "c1",
      complete: true,
      diff: { root: "/repo", files: [listed], ...omitted },
    });
    expect(load.state).toBe("loaded");
    // Unsent choices keep the tool-call view; the checkpoint still says files were left out.
    const display = turnDisplay(translatorFor("en"), turn(["/repo/src/a.ts"]), load, true);
    expect(display.source).toBe("tools");
    expect(display.partial).toBe(true);
    const container = dom.window.document.getElementById("root")!;
    const root = createRoot(container);
    try {
      await act(async () =>
        root.render(<DiffPanel files={display.files} turn={display} root="/repo" onClose={() => {}} />),
      );
      await settle();
      expect(container.querySelector(".acpmux-diff-no-tests")).toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("a view opened on a relative tool path keeps that generated file open once the checkpoint lists it by its absolute path", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const folded = () =>
    [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")]
      .filter((block) => block.dataset.collapsed !== undefined)
      .map((block) => block.dataset.path);
  try {
    // The tool call wrote `bun.lock` relative to the chat's folder; the view opens on it.
    await act(async () =>
      root.render(
        <DiffPanel files={turn(["src/a.ts", "bun.lock"])} root="/repo" initialPath="bun.lock" onClose={() => {}} />,
      ),
    );
    await settle();
    expect(folded()).toEqual([]);
    // The checkpoint loads and lists the same files under the repository's absolute path; another
    // generated file beside it still folds.
    await act(async () =>
      root.render(
        <DiffPanel
          files={turn(["/repo/src/a.ts", "/repo/bun.lock", "/repo/yarn.lock"])}
          turn={{ source: "checkpoint" }}
          root="/repo"
          initialPath="bun.lock"
          onClose={() => {}}
        />,
      ),
    );
    await settle();
    expect(folded()).toEqual(["/repo/yarn.lock"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a generated file folded under its relative tool path stays folded once the checkpoint lists it absolutely", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const folded = () =>
    [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")]
      .filter((block) => block.dataset.collapsed !== undefined)
      .map((block) => block.dataset.path);
  try {
    await act(async () =>
      root.render(<DiffPanel files={turn(["src/a.ts", "bun.lock"])} root="/repo" onClose={() => {}} />),
    );
    await settle();
    expect(folded()).toEqual(["bun.lock"]);
    await act(async () =>
      root.render(
        <DiffPanel
          files={turn(["/repo/src/a.ts", "/repo/bun.lock"])}
          turn={{ source: "checkpoint" }}
          root="/repo"
          onClose={() => {}}
        />,
      ),
    );
    await settle();
    expect(folded()).toEqual(["/repo/bun.lock"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a generated file the reader opened by its relative tool path stays open once the checkpoint lists it absolutely", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const folded = () =>
    [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")]
      .filter((block) => block.dataset.collapsed !== undefined)
      .map((block) => block.dataset.path);
  try {
    await act(async () =>
      root.render(<DiffPanel files={turn(["src/a.ts", "bun.lock"])} root="/repo" onClose={() => {}} />),
    );
    await settle();
    expect(folded()).toEqual(["bun.lock"]);
    // The reader opens it from its header.
    const header = [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")]
      .find((block) => block.dataset.path === "bun.lock")
      ?.querySelector<HTMLButtonElement>(".acpmux-fh-name");
    expect(header).toBeDefined();
    await act(async () => header!.click());
    await settle();
    expect(folded()).toEqual([]);
    await act(async () =>
      root.render(
        <DiffPanel
          files={turn(["/repo/src/a.ts", "/repo/bun.lock"])}
          turn={{ source: "checkpoint" }}
          root="/repo"
          onClose={() => {}}
        />,
      ),
    );
    await settle();
    expect(folded()).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("opening the view by a relative path on an already folded generated file unfolds it", async () => {
  const files = turn(["/repo/src/a.ts", "/repo/bun.lock"]);
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const folded = () =>
    [...container.querySelectorAll<HTMLElement>(".acpmux-diff-file")]
      .filter((block) => block.dataset.collapsed !== undefined)
      .map((block) => block.dataset.path);
  try {
    await act(async () => root.render(<DiffPanel files={files} root="/repo" onClose={() => {}} />));
    await settle();
    expect(folded()).toEqual(["/repo/bun.lock"]);
    // A tool call wrote it as `bun.lock`, relative to the chat's folder.
    await act(async () =>
      root.render(<DiffPanel files={files} root="/repo" initialPath="bun.lock" onClose={() => {}} />),
    );
    await settle();
    expect(folded()).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a file under /private/tmp is read from a chat folder under /tmp", async () => {
  const view = await render(
    turn(["/private/tmp/repo/tests/helpers.py", "/private/tmp/repo/src/a.ts", "/private/tmp/repo/generated/out.ts"]),
    "/tmp/repo",
  );
  try {
    expect(view.kinds()).toEqual(["", "Tests", "Generated"]);
    // A test changed beside the code: nothing is missing.
    expect(view.noTests()).toBeUndefined();
    expect(view.folded()).toEqual(["/private/tmp/repo/generated/out.ts"]);
  } finally {
    await view.unmount();
  }
});
