import { afterAll, describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  dependencyCacheName,
  isDependencyCacheRequest,
  isLoopbackHost,
  payloadFor,
  readBody,
  resolveResource,
  rpcRequestStatus,
} from "../dev-server/diffHost";
import { diffLanguagesDirectory, readDiffLanguagePack } from "../dev-server/diffLanguages";
import {
  SHELL_PLACEHOLDERS,
  cmuxConfigFile,
  contentHash,
  fillShell,
  markdownAsset,
  markdownFiles,
  readMarkdown,
  readMarkdownLook,
  saveMarkdown,
  splitStyles,
  stripJSONC,
} from "../dev-server/markdownHost";

const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "dev-server-test-")));
afterAll(() => fs.rmSync(scratch, { recursive: true, force: true }));

function write(file: string, text = "x"): string {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  return file;
}

describe("diff dev host resource route", () => {
  const root = path.join(scratch, "diff-root");
  const token = "0123456789abcdef0123";
  const patch = write(path.join(root, "session/patch.diff"), "diff --git a b\n");
  const outside = write(path.join(scratch, "outside.diff"));
  fs.symlinkSync(outside, path.join(root, "escape.diff"));
  fs.mkdirSync(path.join(root, "dir"));
  write(
    path.join(root, `.manifest-${token}.json`),
    JSON.stringify({
      token,
      files: [
        { request_path: "/session/patch.diff", file_path: patch, mime_type: "text/x-diff", remote_url: null },
        { request_path: "/outside.diff", file_path: outside, mime_type: "text/x-diff", remote_url: null },
        { request_path: "/escape.diff", file_path: path.join(root, "escape.diff"), mime_type: "text/x-diff" },
        { request_path: "/remote.diff", file_path: patch, mime_type: "text/x-diff", remote_url: "https://x" },
        { request_path: "/dir", file_path: path.join(root, "dir"), mime_type: "text/plain" },
        { request_path: "/missing.diff", file_path: path.join(root, "missing.diff"), mime_type: "text/x-diff" },
      ],
    }),
  );

  test("serves a listed file inside the root, patches as text", () => {
    expect(resolveResource(root, `${token}/session/patch.diff`)).toEqual({
      file: patch,
      contentType: "text/plain; charset=utf-8",
    });
  });

  test("refuses files outside the root, through a symlink, remote, directories and missing files", () => {
    for (const name of ["outside.diff", "escape.diff", "remote.diff", "dir", "missing.diff"]) {
      expect(resolveResource(root, `${token}/${name}`)).toBeUndefined();
    }
  });

  test("refuses unlisted paths, traversal and malformed or unknown tokens", () => {
    expect(resolveResource(root, `${token}/session/other.diff`)).toBeUndefined();
    expect(resolveResource(root, `${token}/../outside.diff`)).toBeUndefined();
    expect(resolveResource(root, token)).toBeUndefined();
    expect(resolveResource(root, `short/session/patch.diff`)).toBeUndefined();
    expect(resolveResource(root, `../../${token}/session/patch.diff`)).toBeUndefined();
    expect(resolveResource(root, `ffffffffffffffffffff/session/patch.diff`)).toBeUndefined();
  });

  test("refuses a manifest whose token does not match its file name", () => {
    const other = "abcdefabcdefabcdef00";
    write(
      path.join(root, `.manifest-${other}.json`),
      JSON.stringify({ token, files: [{ request_path: "/p", file_path: patch, mime_type: "text/x-diff" }] }),
    );
    expect(resolveResource(root, `${other}/p`)).toBeUndefined();
  });
});

describe("diff dev host RPC validation", () => {
  const port = 4210;
  const request = (method: string, headers: Record<string, string>) => ({ method, headers });

  test("accepts POST from the page's own origin or no origin, on a loopback Host", () => {
    expect(rpcRequestStatus(request("POST", { host: "127.0.0.1:4210", origin: "http://127.0.0.1:4210" }), port)).toBe(
      0,
    );
    expect(rpcRequestStatus(request("POST", { host: "localhost:4210", origin: "http://localhost:4210" }), port)).toBe(
      0,
    );
    expect(rpcRequestStatus(request("POST", { host: "127.0.0.1:4210" }), port)).toBe(0);
  });

  test("refuses other methods, foreign origins and rebound hosts", () => {
    expect(rpcRequestStatus(request("GET", { host: "127.0.0.1:4210" }), port)).toBe(405);
    expect(rpcRequestStatus(request("POST", { host: "127.0.0.1:4210", origin: "https://example.com" }), port)).toBe(
      403,
    );
    expect(rpcRequestStatus(request("POST", { host: "127.0.0.1:4210", origin: "http://127.0.0.1:4220" }), port)).toBe(
      403,
    );
    expect(rpcRequestStatus(request("POST", { host: "evil.example:4210" }), port)).toBe(403);
    expect(rpcRequestStatus(request("POST", {}), port)).toBe(403);
    expect(isLoopbackHost("127.0.0.1:4211", port)).toBe(false);
  });

  test("reads a body up to the limit and rejects a larger one", async () => {
    const stream = (chunks: string[]) => {
      const emitter = new EventEmitter();
      queueMicrotask(() => {
        for (const chunk of chunks) emitter.emit("data", Buffer.from(chunk));
        emitter.emit("end");
      });
      return emitter;
    };
    expect((await readBody(stream(["ab", "cd"]), 4)).toString()).toBe("abcd");
    await expect(readBody(stream(["ab", "cde"]), 4)).rejects.toThrow("request too large");
  });

  test("the page config picks the source and layout from the query", () => {
    const host = { token: "t", protocolVersion: 3 };
    const branch = payloadFor(host, "/repo", "HEAD~5", new URLSearchParams("")).payload;
    expect(branch).toMatchObject({
      title: "Branch diff vs HEAD~5",
      transport: { kind: "fetch", endpoint: "/__cmux-diff/rpc", protocolVersion: 3 },
      capabilityToken: "t",
      sessionSource: { kind: "branch", repoRoot: "/repo", baseRef: "HEAD~5" },
      layout: "split",
      layoutSource: "default",
    });
    const staged = payloadFor(host, "/repo", "HEAD~5", new URLSearchParams("source=staged&layout=unified")).payload;
    expect(staged).toMatchObject({ title: "Staged diff", layout: "unified", layoutSource: "explicit" });
    expect(staged.sessionSource).toEqual({ kind: "staged", repoRoot: "/repo" });
    expect(payloadFor(host, "/repo", "HEAD~5", new URLSearchParams("source=bogus")).payload.sessionSource.kind).toBe(
      "branch",
    );
  });
});

describe("markdown dev host file resolution", () => {
  const root = path.join(scratch, "md-root");
  const readme = write(path.join(root, "README.md"), "# hi");
  const guide = write(path.join(root, "docs/guide.markdown"));
  write(path.join(root, ".env"), "SECRET=1");
  write(path.join(root, "notes.txt"));
  fs.mkdirSync(path.join(root, "folder.md"));
  const outside = write(path.join(scratch, "outside.md"));
  fs.symlinkSync(outside, path.join(root, "linked.md"));
  fs.symlinkSync(path.join(root, ".env"), path.join(root, "env.md"));
  const files = markdownFiles(root, readme);

  test("serves markdown files below the root, absolute or root-relative, default when empty", () => {
    expect(files.file("")).toBe(readme);
    expect(files.file("README.md")).toBe(readme);
    expect(files.file(guide)).toBe(guide);
  });

  test("refuses non-markdown, directories, files outside the root and symlinks out", () => {
    for (const requested of [".env", "notes.txt", "folder.md", outside, "../outside.md", "linked.md", "env.md", root]) {
      expect(files.file(requested)).toBeUndefined();
    }
    expect(files.file("missing.md")).toBeUndefined();
  });

  test("links resolve relative to an allowed file, drop fragments, stay under the root", () => {
    expect(files.link(readme, "docs/guide.markdown#setup")).toBe(guide);
    expect(files.link(guide, "../README.md?plain")).toBe(readme);
    expect(files.link(guide, " ../README.md ")).toBe(readme);
    expect(files.link(readme, "../outside.md")).toBeUndefined();
    expect(files.link(readme, ".env")).toBeUndefined();
    expect(files.link(readme, "")).toBeUndefined();
    expect(files.link(path.join(root, ".env"), "README.md")).toBeUndefined();
  });
});

describe("markdown editor dev host", () => {
  const root = path.join(scratch, "md-editor-root");
  const doc = write(path.join(root, "docs/doc.md"), "# Doc\n");
  write(path.join(root, "docs/images/a.png"), "png");
  write(path.join(root, "docs/notes.txt"), "text");
  write(path.join(root, "secret.png"), "png");
  const readOnlyRoot = path.join(scratch, "md-readonly-root");
  const outsideDoc = write(path.join(readOnlyRoot, "ref.md"), "# Ref\n");
  const files = markdownFiles(root, doc, [readOnlyRoot]);

  test("read-only roots open but never save", () => {
    expect(files.file(outsideDoc)).toBe(outsideDoc);
    expect(files.writable(outsideDoc)).toBe(false);
    expect(files.writable(doc)).toBe(true);
    expect(saveMarkdown(outsideDoc, "# Changed\n", contentHash("# Ref\n"), files.writable(outsideDoc))).toEqual({
      ok: false,
      code: "cmux.markdown.read_only",
    });
    expect(fs.readFileSync(outsideDoc, "utf8")).toBe("# Ref\n");
  });

  test("save writes on a matching hash and refuses a stale one with the current text", () => {
    const base = readMarkdown(doc)!;
    const saved = saveMarkdown(doc, "# Doc 2\n", base.hash, true);
    expect(saved).toEqual({ ok: true, hash: contentHash("# Doc 2\n") });
    expect(fs.readFileSync(doc, "utf8")).toBe("# Doc 2\n");
    expect(saveMarkdown(doc, "# Doc 3\n", base.hash, true)).toEqual({
      ok: false,
      code: "cmux.markdown.conflict",
      details: { hash: contentHash("# Doc 2\n"), text: "# Doc 2\n" },
    });
    expect(fs.readFileSync(doc, "utf8")).toBe("# Doc 2\n");
  });

  test("a save over a deleted file is a conflict; a null base hash creates it", () => {
    const gone = path.join(root, "docs/gone.md");
    expect(saveMarkdown(gone, "x", contentHash("old"), true)).toEqual({
      ok: false,
      code: "cmux.markdown.conflict",
      details: { hash: null, deleted: true },
    });
    expect(saveMarkdown(gone, "x\n", null, true).ok).toBe(true);
  });

  test("a file that is not UTF-8 is reported so it opens read only", () => {
    const latin = path.join(root, "docs/latin.md");
    fs.writeFileSync(latin, Buffer.from([0x23, 0x20, 0xe9, 0x0a]));
    expect(readMarkdown(latin)?.utf8).toBe(false);
    expect(readMarkdown(doc)?.utf8).toBe(true);
  });

  test("resolveLinks answers relative targets inside the roots, with their kind", () => {
    write(path.join(root, "docs/other.md"), "# O\n");
    expect(files.target(doc, "other.md")).toEqual({
      exists: true,
      path: path.join(root, "docs/other.md"),
      kind: "markdown",
    });
    expect(files.target(doc, "images/a.png")).toEqual({
      exists: true,
      path: path.join(root, "docs/images/a.png"),
      kind: "file",
    });
    expect(files.target(doc, "images")).toEqual({
      exists: true,
      path: path.join(root, "docs/images"),
      kind: "directory",
    });
    expect(files.target(doc, "missing.md").exists).toBe(false);
    expect(files.target(doc, "../../outside.md")).toEqual({ exists: false });
    expect(files.target(doc, "/etc/passwd")).toEqual({ exists: false });
  });

  test("listFiles completes paths relative to the file, folders first, no dotfiles", () => {
    write(path.join(root, "docs/.hidden.md"), "x");
    expect(files.list(doc, "")).toEqual(["images/", "doc.md", "gone.md", "latin.md", "notes.txt", "other.md"]);
    expect(files.list(doc, "images/")).toEqual(["images/a.png"]);
    expect(files.list(doc, "o")).toEqual(["other.md"]);
    expect(files.list(doc, "../../")).toEqual([]);
  });

  test("images resolve only inside the file's folder", () => {
    expect(markdownAsset(doc, "images/a.png")).toEqual({
      file: path.join(root, "docs/images/a.png"),
      contentType: "image/png",
    });
    expect(markdownAsset(doc, "../secret.png")).toBeUndefined();
    expect(markdownAsset(doc, "notes.txt")).toBeUndefined();
    expect(markdownAsset(doc, "images/missing.png")).toBeUndefined();
  });
});

describe("markdown editor dev look", () => {
  test("reads the markdown section of a JSONC cmux.json and markdown/theme.css next to it", () => {
    const config = write(
      path.join(scratch, "look/cmux.json"),
      '{\n  // comment\n  "url": "https://x//y", /* block */\n  "markdown": { "font": { "size": 18, }, },\n}\n',
    );
    write(path.join(scratch, "look/markdown/theme.css"), ".md-prose { color: red; }");
    expect(readMarkdownLook(config)).toEqual({
      settings: { font: { size: 18 } },
      themeCSS: ".md-prose { color: red; }",
    });
    expect(JSON.parse(stripJSONC('{"a": "//not a comment", "b": [1,],}'))).toEqual({ a: "//not a comment", b: [1] });
  });

  test("a missing config or stylesheet is an empty look; CMUX_NEXT_CONFIG_FILE moves cmux.json", () => {
    expect(readMarkdownLook(path.join(scratch, "nowhere/cmux.json"))).toEqual({ settings: undefined, themeCSS: "" });
    expect(cmuxConfigFile({ CMUX_NEXT_CONFIG_FILE: "/tmp/x/cmux.json" }, "/home/u")).toBe("/tmp/x/cmux.json");
    expect(cmuxConfigFile({}, "/home/u")).toBe("/home/u/.config/cmux/cmux.json");
  });
});

describe("markdown dev host shell fill", () => {
  const assets = Object.fromEntries(Object.values(SHELL_PLACEHOLDERS).map((name) => [name, `/*${name}*/`]));
  assets["marked.min.js"] = "x.replace(/a/, '$&$1')";
  const template = [
    "<html><head>",
    ...Object.keys(SHELL_PLACEHOLDERS).map((key) =>
      key.endsWith("CSS") ? `<style>{{${key}}}</style>` : `<script>{{${key}}}</script>`,
    ),
    "<script>const strings = {{localizedStringsJSON}};</script>",
    '<style media="print">p{}</style>',
    "</head><body></body></html>",
  ].join("\n");
  const html = fillShell(template, (name: string) => assets[name]);

  test("fills every placeholder verbatim and leaves none behind", () => {
    expect(html).not.toContain("{{");
    for (const name of Object.values(SHELL_PLACEHOLDERS)) expect(html).toContain(assets[name]);
    expect(html).toContain("const strings = {};");
  });

  test("tags each style by index so a stylesheet edit can replace it in place", () => {
    expect(html).toContain('<style data-cmux-shell-style="0">/*github-markdown.css*/</style>');
    expect(html).toContain('<style data-cmux-shell-style="3" media="print">');
    const { styles, skeleton } = splitStyles(html);
    expect(styles).toEqual([
      "/*github-markdown.css*/",
      "/*highlight-github.css*/",
      "/*highlight-github-dark.css*/",
      "p{}",
    ]);
    expect(splitStyles(html.replace("p{}", "p{color:red}")).skeleton).toBe(skeleton);
    expect(splitStyles(html.replace("<body>", "<body><p>")).skeleton).not.toBe(skeleton);
  });
});

describe("diff languages folder (dev host)", () => {
  test("lives next to cmux.json and moves with CMUX_NEXT_CONFIG_FILE", () => {
    expect(diffLanguagesDirectory({}, "/Users/me")).toBe("/Users/me/.config/cmux/diff/languages");
    expect(diffLanguagesDirectory({ CMUX_NEXT_CONFIG_FILE: "/tmp/x/cmux.json" }, "/Users/me")).toBe(
      "/tmp/x/diff/languages",
    );
  });

  test("sends every JSON file as text and skips other files", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-diff-languages-"));
    fs.writeFileSync(path.join(dir, "foo.language.json"), '{"id":"foo"}');
    fs.mkdirSync(path.join(dir, "grammars"));
    fs.writeFileSync(path.join(dir, "grammars", "foo.tmLanguage.json"), "{}");
    fs.writeFileSync(path.join(dir, "notes.txt"), "x");
    fs.writeFileSync(path.join(dir, ".hidden.json"), "{}");
    expect(readDiffLanguagePack(dir)).toEqual({
      files: [
        { path: "foo.language.json", text: '{"id":"foo"}' },
        { path: "grammars/foo.tmLanguage.json", text: "{}" },
      ],
    });
    expect(readDiffLanguagePack(path.join(dir, "missing"))).toEqual({ files: [] });
    fs.rmSync(dir, { recursive: true });
  });
});

describe("optimized dependency caching", () => {
  test("each port has its own cache, and only its modules are revalidated", () => {
    const name = dependencyCacheName(4181);
    expect(name).toBe(".vite-dev-deps-4181");
    expect(isDependencyCacheRequest(`/node_modules/${name}/deps/shiki.js`, name)).toBe(true);
    expect(isDependencyCacheRequest(`/node_modules/${dependencyCacheName(4182)}/deps/shiki.js`, name)).toBe(false);
    expect(isDependencyCacheRequest("/src/App.tsx", name)).toBe(false);
  });
});
