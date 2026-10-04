import { describe, expect, test } from "bun:test";
import { pageError, type PageClient } from "../shared/pageClient";
import { MARKDOWN_CHANGES, type MarkdownChange } from "./host";
import { LinkRouter } from "./linkRouter";
import { LinkResolver, Slugger, githubSlug, parseLink, pastedURL, type ResolvedLink } from "./links";
import type { SourceMap } from "./sourceMap";
import { MarkdownStore, type DocumentEditor } from "./store";

describe("parseLink", () => {
  test("kinds", () => {
    expect(parseLink("#Setup-1")).toEqual({ kind: "anchor", href: "#Setup-1", path: "", anchor: "Setup-1" });
    expect(parseLink("docs/a%20b.md#install")).toEqual({
      kind: "markdown",
      href: "docs/a%20b.md#install",
      path: "docs/a b.md",
      anchor: "install",
    });
    expect(parseLink("./img/logo.png?raw=1").kind).toBe("file");
    expect(parseLink("../src/main.ts").path).toBe("../src/main.ts");
    expect(parseLink("https://cmux.dev").kind).toBe("external");
    expect(parseLink("mailto:a@b.dev").kind).toBe("mail");
    expect(parseLink("tel:+1").kind).toBe("mail");
    expect(parseLink("javascript:alert(1)").kind).toBe("unsafe");
    expect(parseLink("").kind).toBe("unsafe");
  });

  test("pasted URLs: one http(s) or mailto URL only", () => {
    expect(pastedURL(" https://cmux.dev/a?b=1 ")).toBe("https://cmux.dev/a?b=1");
    expect(pastedURL("mailto:a@b.dev")).toBe("mailto:a@b.dev");
    expect(pastedURL("see https://cmux.dev")).toBe(null);
    expect(pastedURL("javascript:alert(1)")).toBe(null);
  });
});

describe("GitHub slugs", () => {
  test("punctuation, case, spaces, scripts", () => {
    expect(githubSlug("Hello, World!")).toBe("hello-world");
    expect(githubSlug("API: v2 (beta)")).toBe("api-v2-beta");
    expect(githubSlug("A  B")).toBe("a--b");
    expect(githubSlug("snake_case and-dash")).toBe("snake_case-and-dash");
    expect(githubSlug("日本語の見出し")).toBe("日本語の見出し");
    expect(githubSlug("Emoji 🚀 here")).toBe("emoji--here");
  });

  test("repeats get -1, -2, and a heading named like a suffix is not reused", () => {
    const slugger = new Slugger();
    expect(["Setup", "Setup", "Setup-1", "Setup"].map((text) => slugger.slug(text))).toEqual([
      "setup",
      "setup-1",
      "setup-1-1",
      "setup-2",
    ]);
  });
});

describe("LinkResolver", () => {
  test("batches one call per tick, caches, and forgets on a new file", async () => {
    const calls: Array<[string, string[]]> = [];
    let resolved = 0;
    const resolver = new LinkResolver(
      async (from, paths) => {
        calls.push([from, paths]);
        return Object.fromEntries(paths.map((path) => [path, { exists: path !== "gone.md" }]));
      },
      () => resolved++,
    );
    resolver.setFrom("/w/a.md");
    resolver.request(["b.md", "gone.md"]);
    resolver.request(["b.md", "c.png"]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(calls).toEqual([["/w/a.md", ["b.md", "gone.md", "c.png"]]]);
    expect(resolver.get("gone.md")).toEqual({ exists: false });
    expect(resolved).toBe(1);
    resolver.request(["b.md"]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(calls.length).toBe(1);
    resolver.setFrom("/w/docs/x.md");
    expect(resolver.get("b.md")).toBe(undefined);
  });
});

/** A host with files, link answers and an openLink log. */
class FakeHost implements PageClient {
  files = new Map<string, string>([
    ["/w/a.md", "# A\n"],
    ["/w/docs/b.md", "# B\n\n## Install\n"],
  ]);
  opened: unknown[] = [];
  loads: string[] = [];
  saves: string[] = [];
  onChange: ((change: MarkdownChange, seq: number) => void) | null = null;
  links: Record<string, ResolvedLink> = {
    "docs/b.md": { exists: true, path: "/w/docs/b.md", kind: "markdown" },
    "src/main.ts": { exists: true, path: "/w/src/main.ts", kind: "file" },
    "gone.md": { exists: false },
  };
  async call<R>(op: string, params: unknown): Promise<R> {
    const p = params as Record<string, unknown>;
    const file = (path: string) => ({ path, text: this.files.get(path)!, hash: `h:${this.files.get(path) ?? ""}` });
    if (op === "cmux.markdown.config") return file("/w/a.md") as R;
    if (op === "cmux.markdown.load") {
      this.loads.push(String(p.path));
      if (!this.files.has(String(p.path))) throw pageError("cmux.markdown.not_found", "x");
      return file(String(p.path)) as R;
    }
    if (op === "cmux.markdown.save") {
      this.saves.push(String(p.path));
      this.files.set(String(p.path), String(p.text));
      return { hash: `h:${String(p.text)}` } as R;
    }
    if (op === "cmux.markdown.openLink") {
      this.opened.push(params);
      return {} as R;
    }
    if (op === "cmux.markdown.resolveLinks") {
      return {
        links: Object.fromEntries((p.paths as string[]).map((path) => [path, this.links[path] ?? { exists: false }])),
      } as R;
    }
    throw pageError("cmux.protocol.unknown_op", op);
  }
  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === MARKDOWN_CHANGES) this.onChange = onEvent as never;
    return () => {};
  }
  handle(): () => void {
    return () => {};
  }
}

class FakeEditor implements DocumentEditor {
  text = "";
  load(text: string): void {
    this.text = text;
  }
  snapshot(): SourceMap {
    return { text: this.text, blocks: [] };
  }
  commit(): void {}
  setReadOnly(): void {}
}

async function setup() {
  const host = new FakeHost();
  const store = new MarkdownStore(host, () => () => {});
  const editor = new FakeEditor();
  store.attachEditor(editor);
  await store.start();
  const anchors: string[] = [];
  let scroll = 0;
  const router = new LinkRouter({
    store,
    client: host,
    resolver: { get: () => undefined },
    scrollToAnchor: (anchor) => {
      anchors.push(anchor);
      return anchor !== "missing";
    },
    scroll: { get: () => scroll, set: (top) => void (scroll = top) },
  });
  return {
    host,
    store,
    editor,
    router,
    anchors,
    setScroll: (top: number) => void (scroll = top),
    scroll: () => scroll,
  };
}

describe("following links", () => {
  test("#anchor scrolls in this file", async () => {
    const { router, anchors, host } = await setup();
    await router.follow("#install");
    expect(anchors).toEqual(["install"]);
    expect(host.loads).toEqual([]);
  });

  test("http(s) and mailto go to the host's openLink", async () => {
    const { router, host } = await setup();
    await router.follow("https://cmux.dev");
    await router.follow("mailto:a@b.dev");
    await router.follow("javascript:alert(1)");
    expect(host.opened).toEqual([
      { path: "/w/a.md", href: "https://cmux.dev", kind: "external" },
      { path: "/w/a.md", href: "mailto:a@b.dev", kind: "mail" },
    ]);
  });

  test("other relative files open in the file viewer; missing targets go nowhere", async () => {
    const { router, host } = await setup();
    await router.follow("src/main.ts");
    await router.follow("gone.md");
    expect(host.opened).toEqual([{ path: "/w/a.md", href: "src/main.ts", kind: "file", target: "/w/src/main.ts" }]);
    expect(host.loads).toEqual([]);
  });

  test("a markdown link opens in the page, then scrolls to its #heading; back and forward", async () => {
    const { router, host, store, editor, anchors, setScroll, scroll } = await setup();
    setScroll(120);
    await router.follow("docs/b.md#install");
    expect(host.loads).toEqual(["/w/docs/b.md"]);
    expect(store.getState().config?.path).toBe("/w/docs/b.md");
    expect(editor.text).toBe("# B\n\n## Install\n");
    expect(anchors).toEqual(["install"]);
    expect(store.getState().canBack).toBe(true);
    await router.go(-1);
    expect(store.getState().config?.path).toBe("/w/a.md");
    expect(scroll()).toBe(120);
    expect(store.getState().canForward).toBe(true);
    await router.go(1);
    expect(store.getState().config?.path).toBe("/w/docs/b.md");
    expect(store.getState().canForward).toBe(false);
  });

  test("leaving a file saves its edits first; changes of the file left behind are ignored", async () => {
    const { router, host, store, editor } = await setup();
    editor.text = "# A edited\n";
    store.edited();
    await router.follow("docs/b.md");
    expect(host.saves).toEqual(["/w/a.md"]);
    expect(host.files.get("/w/a.md")).toBe("# A edited\n");
    host.onChange?.({ path: "/w/a.md", hash: "h:other", text: "# other\n" }, 1);
    expect(editor.text).toBe("# B\n\n## Install\n");
    expect(store.getState().conflict).toBe(null);
  });
});
