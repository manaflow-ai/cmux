import { expect, test } from "bun:test";
import { errorFile, errorKind, scopeOf, type ScopeNode } from "../dev-server/galleryLive";

const node = (file: string, importers: ScopeNode[] = []): ScopeNode => ({ file, importers: new Set(importers) });
const entry = (file: string) => `/repo/webviews/src/agent-session/acpmux/${file}.gallery.tsx`;
const shell = "/repo/webviews/src/gallery/shell/main.tsx";
const stage = "/repo/webviews/src/gallery/frame/main.ts";
const isEntry = (file: string) => /\.gallery\.tsx?$/.test(file);
const isShell = (file: string) => file === shell;

test("compile errors reached only through an entry stay entry-scoped", () => {
  const source = node(entry("Composer"));
  const importer = node("/repo/webviews/src/agent-session/acpmux/Composer.tsx", [source]);
  const scope = scopeOf([importer], isEntry, isShell);
  expect(errorKind(scope)).toBe("entry");
  expect(scope.entries.map((item) => item.file)).toEqual([source.file]);
});

test("shell and stage roots remain distinct error surfaces", () => {
  const shellScope = scopeOf([node("/repo/webviews/src/gallery/format.ts", [node(shell)])], isEntry, isShell);
  const stageScope = scopeOf([node("/repo/webviews/src/ui/Popover.tsx", [node(stage)])], isEntry, isShell);
  expect(errorKind(shellScope)).toBe("shell");
  expect(errorKind(stageScope)).toBe("stage");
});

test("errorFile prefers explicit ids and falls back to compiler message paths", () => {
  expect(errorFile({ id: "/repo/webviews/src/ui/Popover.tsx?direct", message: "ignored" }, "/repo/webviews")).toBe(
    "/repo/webviews/src/ui/Popover.tsx",
  );
  expect(
    errorFile(
      { message: "transform failed at /repo/webviews/src/agent-session/acpmux/Composer.tsx:12:4" },
      "/repo/webviews",
    ),
  ).toBe("/repo/webviews/src/agent-session/acpmux/Composer.tsx");
});
