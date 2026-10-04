// The diff and markdown empty states against fake hosts: recents with name, path and time,
// keyboard navigation, choosing through the host picker, the diff source step, drops, errors, and
// the boot paths that show them (bootPageDiff for a config without a repository, MarkdownStore for
// one without a file).
import { click, press, render, installDom, restoreDom, settle, unmount } from "./viewer-empty-dom";
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { bootPageDiff } from "../src/diff/pageBoot";
import { createDiffViewerLabelResolver } from "../src/labels";
import { MarkdownPage } from "../src/pages/markdown/MarkdownPage";
import { MarkdownStore } from "../src/pages/markdown/store";
import { createStrings } from "../src/pages/shared/i18n";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import { DiffEmptyState } from "../src/viewer-empty/DiffEmptyState";
import { MarkdownEmptyState } from "../src/viewer-empty/MarkdownEmptyState";
import { viewerEmptyStrings } from "../src/viewer-empty/strings";

afterEach(() => unmount());
beforeAll(() => installDom());
afterAll(() => restoreDom());

const strings = viewerEmptyStrings(["en"]);
const label = createDiffViewerLabelResolver(undefined, { language: "en" });
const NOW = Date.UTC(2026, 9, 4, 12);
const minutes = (count: number) => NOW - count * 60_000;

/** A host that answers ops from `answers` (a value or a function of the params) and logs calls. */
function fakeHost(answers: Record<string, unknown>) {
  const calls: Array<{ op: string; params: unknown }> = [];
  const client: PageClient = {
    async call<R>(op: string, params: unknown): Promise<R> {
      calls.push({ op, params });
      if (!(op in answers)) throw pageError("cmux.protocol.unknown_op", op);
      const answer = answers[op];
      return (typeof answer === "function" ? await answer(params) : answer) as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  return { client, calls };
}

const diffRecents = {
  home: "/Users/me",
  items: [
    { path: "/Users/me/fun/chatmux", openedAt: minutes(60 * 26), branch: "main" },
    { path: "/Users/me/fun/cmux", openedAt: minutes(5), source: "staged", branch: "feat-x" },
  ],
};

const rows = (container: HTMLElement) =>
  [...container.querySelectorAll(".ve-recent")].map((row) => ({
    name: row.querySelector(".ve-recent-name")?.textContent,
    path: row.querySelector(".ve-tail-path")?.textContent?.replaceAll("‎", ""),
    branch: row.querySelector(".ve-recent-branch")?.textContent ?? null,
    time: row.querySelector(".ve-recent-time")?.textContent,
    selected: row.getAttribute("aria-selected"),
  }));

describe("diff empty state", () => {
  async function mountDiff(answers: Record<string, unknown>) {
    const host = fakeHost({ "cmux.diff.recents": diffRecents, ...answers });
    const opened: unknown[] = [];
    const container = await render(
      <DiffEmptyState
        client={host.client}
        strings={strings}
        label={label}
        now={NOW}
        onOpened={(config) => opened.push(config)}
      />,
    );
    return { ...host, container, opened };
  }

  test("lists recent repositories newest first with name, dim path, branch and relative time", async () => {
    const { container } = await mountDiff({});
    expect(container.querySelector(".ve-title")?.textContent).toBe("Open a repository");
    expect(container.querySelector(".ve-button-primary")?.textContent).toBe("Choose Folder…");
    expect(rows(container)).toEqual([
      { name: "cmux", path: "~/fun", branch: "feat-x", time: "5 min. ago", selected: "true" },
      { name: "chatmux", path: "~/fun", branch: "main", time: "yesterday", selected: "false" },
    ]);
    // The list takes focus so the keys work at once.
    expect(document.activeElement?.classList.contains("ve-recent-list")).toBe(true);
  });

  test("Down and Return pick a recent; the source step preselects its last source; Return opens", async () => {
    const config = { payload: { repoRoot: "/Users/me/fun/chatmux" } };
    const { container, calls, opened } = await mountDiff({ "cmux.diff.open": config });
    const list = container.querySelector(".ve-recent-list")!;
    await press(list, "ArrowDown");
    expect(rows(container).map((row) => row.selected)).toEqual(["false", "true"]);
    await press(list, "Enter");
    expect(container.querySelector(".ve-chosen .ve-recent-name")?.textContent).toBe("chatmux");
    const radios = [...container.querySelectorAll<HTMLInputElement>(".ve-radio")];
    expect(radios.map((radio) => radio.value)).toEqual(["branch", "uncommitted", "staged", "unstaged"]);
    expect(radios.map((radio) => radio.getAttribute("aria-label"))).toEqual([
      "Branch",
      "Uncommitted",
      "Staged",
      "Unstaged",
    ]);
    expect(radios.find((radio) => radio.checked)?.value).toBe("branch");
    expect(document.activeElement).toBe(radios[0]);
    await click(radios[1]);
    expect(container.querySelector<HTMLInputElement>(".ve-radio:checked")?.value).toBe("uncommitted");
    await press(container.querySelector(".ve-radio:checked")!, "Enter");
    expect(calls.at(-1)).toEqual({
      op: "cmux.diff.open",
      params: {
        path: "/Users/me/fun/chatmux",
        source: { kind: "branch", repoRoot: "/Users/me/fun/chatmux", baseRef: "HEAD" },
      },
    });
    expect(opened).toEqual([config]);
  });

  test("a recent remembers its source; Escape goes back to the list", async () => {
    const { container } = await mountDiff({});
    await press(container.querySelector(".ve-recent-list")!, "Enter");
    expect(container.querySelector<HTMLInputElement>(".ve-radio:checked")?.value).toBe("staged");
    await press(container.querySelector(".ve-radio:checked")!, "Escape");
    expect(container.querySelector(".ve-recent-list")).toBeTruthy();
  });

  test("Choose Folder asks the host picker from the newest recent's folder; cancel stays", async () => {
    let answer: unknown = null;
    const { container, calls } = await mountDiff({ "cmux.diff.chooseFolder": () => answer });
    await click(container.querySelector(".ve-button-primary")!);
    expect(calls.at(-1)).toEqual({ op: "cmux.diff.chooseFolder", params: { start: "/Users/me/fun" } });
    expect(container.querySelector(".ve-recent-list")).toBeTruthy();
    answer = { path: "/Users/me/work/new" };
    await click(container.querySelector(".ve-button-primary")!);
    expect(container.querySelector(".ve-chosen .ve-recent-name")?.textContent).toBe("new");
    expect(container.querySelector<HTMLInputElement>(".ve-radio:checked")?.value).toBe("branch");
  });

  test("a folder that is not a repository shows the host's error", async () => {
    const { container, opened } = await mountDiff({
      "cmux.diff.chooseFolder": { path: "/Users/me/Documents" },
      "cmux.diff.open": () => {
        throw pageError("cmux.diff.not_a_repo", "nope");
      },
    });
    await click(container.querySelector(".ve-button-primary")!);
    await click(container.querySelector(".ve-step .ve-button-primary")!);
    expect(container.querySelector(".ve-error")?.textContent).toBe("Documents is not a git repository.");
    expect(opened).toEqual([]);
  });

  test("dropping a folder opens the source step; a drop without a path explains it", async () => {
    const { container } = await mountDiff({});
    const page = container.querySelector(".ve-page")!;
    const drop = async (data: Record<string, string>, files: Array<{ name: string }> = []) =>
      act(async () => {
        const event = new window.Event("drop", { bubbles: true, cancelable: true }) as Event & {
          dataTransfer: unknown;
        };
        event.dataTransfer = { types: Object.keys(data), getData: (type: string) => data[type] ?? "", files };
        page.dispatchEvent(event);
      });
    await drop({}, [{ name: "repo" }]);
    await settle();
    expect(container.querySelector(".ve-error")?.textContent).toBe("Could not open repo.");
    await drop({ "text/uri-list": "file:///Users/me/fun/dropped" });
    await settle();
    expect(container.querySelector(".ve-chosen .ve-recent-name")?.textContent).toBe("dropped");
  });

  test("no recents: the list says where they will appear", async () => {
    const { container } = await mountDiff({ "cmux.diff.recents": { items: [] } });
    expect(container.querySelector(".ve-recents-empty")?.textContent).toBe("Repositories you open appear here.");
  });

  test("Japanese strings", async () => {
    const host = fakeHost({ "cmux.diff.recents": { items: [] } });
    const container = await render(
      <DiffEmptyState client={host.client} strings={viewerEmptyStrings(["ja"])} label={label} onOpened={() => {}} />,
    );
    expect(container.querySelector(".ve-title")?.textContent).toBe("リポジトリを開く");
    expect(container.querySelector(".ve-button-primary")?.textContent).toBe("フォルダを選択…");
  });
});

describe("diff boot", () => {
  test("a config without a repository shows the empty state and renders the opened config", async () => {
    const opened = { payload: { repoRoot: "/r", sessionSource: { kind: "staged", repoRoot: "/r" } } };
    const host = fakeHost({ "cmux.diff.config": { pick: true, payload: { title: "Diff" } } });
    const rendered: unknown[] = [];
    let picked: unknown;
    const config = await bootPageDiff(
      host.client,
      (value) => rendered.push(value),
      () => undefined,
      undefined,
      async (empty) => {
        picked = empty;
        return opened;
      },
    );
    expect((picked as { pick?: boolean }).pick).toBe(true);
    expect(rendered).toHaveLength(1);
    expect(config.payload?.repoRoot).toBe("/r");
    // The opened config gets the page transport, as `cmux.diff.config` answers do.
    expect(config.payload?.transport).toEqual({ kind: "page", endpoint: "", protocolVersion: 1 });
  });

  test("a config with a repository renders without the empty state", async () => {
    const host = fakeHost({ "cmux.diff.config": { payload: { repoRoot: "/r" } } });
    let picks = 0;
    await bootPageDiff(
      host.client,
      () => {},
      () => undefined,
      undefined,
      async () => {
        picks += 1;
        return {};
      },
    );
    expect(picks).toBe(0);
  });
});

describe("markdown empty state", () => {
  const markdownRecents = {
    home: "/Users/me",
    items: [
      { path: "/Users/me/notes/todo.md", openedAt: minutes(150) },
      { path: "/Users/me/fun/cmux/README.md", openedAt: minutes(2) },
    ],
  };
  const fileConfig = (path: string) => ({ path, text: "# Hi\n", hash: "h1" });

  async function mountMarkdown(answers: Record<string, unknown>) {
    const host = fakeHost({
      "cmux.markdown.config": { pick: true },
      "cmux.markdown.recents": markdownRecents,
      ...answers,
    });
    const store = new MarkdownStore(host.client);
    const pageStrings = createStrings({ en: {} }, ["en"]);
    const container = await render(
      <MarkdownPage
        store={store}
        strings={pageStrings}
        editorRef={() => {}}
        emptyState={() => (
          <MarkdownEmptyState client={host.client} strings={strings} now={NOW} open={(path) => store.openFile(path)} />
        )}
      />,
    );
    await act(async () => store.start());
    await settle();
    return { ...host, store, container };
  }

  test("a config without a file shows recent markdown files", async () => {
    const { container, store } = await mountMarkdown({});
    expect(store.getState().phase).toBe("empty");
    expect(container.querySelector(".ve-title")?.textContent).toBe("Open a markdown file");
    expect(container.querySelector(".ve-button-primary")?.textContent).toBe("Choose File…");
    expect(rows(container).map(({ name, path, time }) => ({ name, path, time }))).toEqual([
      { name: "README.md", path: "~/fun/cmux", time: "2 min. ago" },
      { name: "todo.md", path: "~/notes", time: "2 hr. ago" },
    ]);
  });

  test("Return on a recent opens it through cmux.markdown.open and the editor takes over", async () => {
    const { container, store, calls } = await mountMarkdown({
      "cmux.markdown.open": (params: { path: string }) => fileConfig(params.path),
    });
    await press(container.querySelector(".ve-recent-list")!, "ArrowDown");
    await press(container.querySelector(".ve-recent-list")!, "Enter");
    expect(calls.find((call) => call.op === "cmux.markdown.open")?.params).toEqual({ path: "/Users/me/notes/todo.md" });
    expect(store.getState().phase).toBe("ready");
    expect(store.getState().config?.path).toBe("/Users/me/notes/todo.md");
    expect(container.querySelector(".ve-page")).toBeNull();
    expect(container.querySelector(".md-file")?.textContent).toBe("todo.md");
  });

  test("Choose File asks the host picker; a non-markdown answer is refused before opening", async () => {
    const { container, calls } = await mountMarkdown({ "cmux.markdown.chooseFile": { path: "/Users/me/a.txt" } });
    await click(container.querySelector(".ve-button-primary")!);
    expect(calls.at(-1)).toEqual({ op: "cmux.markdown.chooseFile", params: { start: "/Users/me/fun/cmux" } });
    expect(container.querySelector(".ve-error")?.textContent).toBe("a.txt is not a markdown file.");
  });

  test("a host error while opening shows under the actions", async () => {
    const { container } = await mountMarkdown({
      "cmux.markdown.open": () => {
        throw pageError("cmux.markdown.not_found", "gone");
      },
    });
    await press(container.querySelector(".ve-recent-list")!, "Enter");
    expect(container.querySelector(".ve-error")?.textContent).toBe("Could not open README.md.");
  });
});
