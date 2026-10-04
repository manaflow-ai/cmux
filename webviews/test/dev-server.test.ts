import { afterAll, describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isLoopbackHost, payloadFor, readBody, resolveResource, rpcRequestStatus } from "../dev-server/diffHost";
import { diffLanguagesDirectory, readDiffLanguagePack } from "../dev-server/diffLanguages";
import { SHELL_PLACEHOLDERS, fillShell, markdownFiles, splitStyles } from "../dev-server/markdownHost";

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
