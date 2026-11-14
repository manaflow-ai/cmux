// l10n-allow-file: test fixtures.
// What a read or file search found, read out of its result text (fileResults.ts): a read's lines and
// where they start, a search's files and matching lines in every shape the harnesses print them, and
// no card for text it cannot read whole.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { HARNESS_CALLS } from "../toolNamesFixture";
import { fileCard, fileCardText, readPeek, searchResult } from "./fileResults";
import { fileLanguage } from "../shikiLanguages";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const with_ = (tool: Tool, output: string): Tool => ({ ...tool, output });

test("a Claude Read's numbered lines lose their numbers and start where they say", () => {
  expect(readPeek("/w/a.ts", "   120→const a = 1;\n   121→\n   122→export { a };\n")).toEqual({
    path: "/w/a.ts",
    start: 120,
    end: 122,
    code: "const a = 1;\n\nexport { a };",
  });
  // cat -n's tab, as Claude Code prints it now.
  expect(readPeek("/w/a.ts", "1\tline one\n2\tline two")?.code).toBe("line one\nline two");
});

test("plain lines start at the line the read asked for, else 1; numbers that do not count up are no file", () => {
  expect(readPeek("/w/a.ts", "x\ny", 40)).toMatchObject({ start: 40, end: 41, code: "x\ny" });
  expect(readPeek("/w/a.ts", "only")).toMatchObject({ start: 1, end: 1 });
  expect(readPeek("/w/a.ts", "3\tc\n1\ta\n2\tb")).toBeUndefined();
});

test("only Claude's own Read loses tab numbers: another harness's TSV keeps its first column", () => {
  expect(readPeek("/w/a.tsv", "1\tfoo\n2\tbar", 1, false)).toMatchObject({ start: 1, code: "1\tfoo\n2\tbar" });
  const pi = fileCard({ ...HARNESS_CALLS.pi.read, output: "1\tfoo" }, "1\tfoo");
  expect(pi).toMatchObject({ read: { code: "1\tfoo" } });
  const claude = fileCard({ ...HARNESS_CALLS.claude.read, output: "1\tfoo" }, "1\tfoo");
  expect(claude).toMatchObject({ read: { code: "foo" } });
});

test("a files-only Grep's root names without an extension read as files", () => {
  const card = fileCard(HARNESS_CALLS.claude.search, "Found 2 files\nLICENSE\nsrc/a.ts");
  expect(card).toMatchObject({ kind: "search", result: { files: [{ path: "LICENSE" }, { path: "src/a.ts" }] } });
});

test("every harness's read draws a file card; Codex's sed range sets its first line", () => {
  for (const harness of ["claude", "codex", "opencode", "pi", "gemini"] as const) {
    const card = fileCard(with_(HARNESS_CALLS[harness].read, "1\timport x from 'y';"), "1\timport x from 'y';");
    expect(card?.kind, harness).toBe("read");
  }
  const codex = fileCard(with_(HARNESS_CALLS.codex.read, "a\nb"), "a\nb");
  expect(codex).toMatchObject({
    kind: "read",
    read: { path: "/work/app/src/foo.ts", start: 1, end: 2 },
  });
  const ranged = {
    ...HARNESS_CALLS.codex.read,
    inputSummary: JSON.stringify({ command: "sed -n 80,81p src/foo.ts" }),
  };
  expect(fileCard(ranged, "a\nb")).toMatchObject({ read: { start: 80, end: 81 } });
});

test("a running or failed call, an empty result and an unknown tool draw no card", () => {
  const read = HARNESS_CALLS.claude.read;
  expect(fileCard({ ...read, status: "in_progress" }, "1\ta")).toBeUndefined();
  expect(fileCard({ ...read, status: "failed" }, "1\ta")).toBeUndefined();
  expect(fileCard(read, "  \n")).toBeUndefined();
  expect(fileCard({ id: "m", title: "mcp__x__y", kind: "other", status: "completed" }, "a.ts:1:x")).toBeUndefined();
});

test("grep -n lines group by file with their line numbers, under the folder they share", () => {
  const result = searchResult(
    "/w/app/src/a.ts:12:  const x = useTool();\n/w/app/src/a.ts:40:useTool(b)\n/w/app/src/lib/b.ts:3:import { useTool }",
  );
  expect(result).toEqual({
    files: [
      {
        path: "/w/app/src/a.ts",
        shown: "a.ts",
        open: "/w/app/src/a.ts",
        matches: [
          { line: 12, text: "const x = useTool();" },
          { line: 40, text: "useTool(b)" },
        ],
      },
      {
        path: "/w/app/src/lib/b.ts",
        shown: "lib/b.ts",
        open: "/w/app/src/lib/b.ts",
        matches: [{ line: 3, text: "import { useTool }" }],
      },
    ],
    matches: 3,
    truncated: false,
  });
});

test("Claude's files-with-matches, counts and Glob lists, rg's headings and plain lines all read", () => {
  const files = searchResult("Found 2 files\n/w/a.ts\n/w/b/c.ts");
  expect(files?.files.map((file) => file.shown)).toEqual(["a.ts", "b/c.ts"]);
  expect(files?.matches).toBe(0);
  const counts = searchResult("/w/a.ts:3\n/w/b.ts:1\n\nFound 4 total occurrences across 2 files.");
  expect(counts?.files.map((file) => file.count)).toEqual([3, 1]);
  expect(counts?.matches).toBe(4);
  const glob = searchResult(
    "/w/src/a.ts\n/w/src/b.ts\n(Results are truncated. Consider using a more specific path or pattern.)",
  );
  expect(glob).toMatchObject({ truncated: true, files: [{ shown: "a.ts" }, { shown: "b.ts" }] });
  // rg --heading: a file, then its lines; a context line (`13-`) is not a match.
  const heading = searchResult("src/a.ts\n12:useTool()\n13-next line\n\nsrc/b.ts\n4:useTool", "/w");
  expect(heading?.files.map((file) => [file.open, file.matches.length])).toEqual([
    ["/w/src/a.ts", 1],
    ["/w/src/b.ts", 1],
  ]);
  // rg without numbers (Codex's `rg useTool`).
  expect(searchResult("src/a.ts:const x = useTool()", "/w")?.files[0]).toMatchObject({
    open: "/w/src/a.ts",
    matches: [{ text: "const x = useTool()" }],
  });
});

test("a Glob's root files without an extension read as files; a text search's do not", () => {
  expect(searchResult("LICENSE\nMakefile\nsrc/a.ts", "/w", true)?.files.map((file) => file.open)).toEqual([
    "/w/LICENSE",
    "/w/Makefile",
    "/w/src/a.ts",
  ]);
  expect(searchResult("LICENSE\nsrc/a.ts", "/w")).toBeUndefined();
});

test("a search result with words a card does not know, or no file, keeps the generic body", () => {
  expect(searchResult("Directory listing for /w:\n[DIR] src")).toBeUndefined();
  expect(searchResult("No files found")).toBeUndefined();
  expect(searchResult("The pattern matched nothing useful here.")).toBeUndefined();
});

test("Find reads a card's lines and paths as drawn, without its numbers or counts", () => {
  const read = fileCard(HARNESS_CALLS.claude.read, "7\tconst a = 1;")!;
  expect(fileCardText(read)).toBe("const a = 1;");
  const search = fileCard(HARNESS_CALLS.claude.search, "/w/src/a.ts:12:useTool()")!;
  expect(search.kind).toBe("search");
  expect(fileCardText(search)).toBe("a.ts\nuseTool()");
  const glob = fileCard(HARNESS_CALLS.claude.glob, "/w/src/a.ts\n/w/src/b.ts");
  expect(glob).toMatchObject({ kind: "search", tool: "glob" });
});

test("a read is highlighted by its file's name, in a bundled language or as text", () => {
  expect(fileLanguage("/w/src/App.tsx")).toBe("tsx");
  expect(fileLanguage("/w/main.rs")).toBe("rust");
  expect(fileLanguage("/w/Makefile")).toBe("make");
  expect(fileLanguage("/w/notes.txt")).toBe("text");
  expect(fileLanguage("/w/LICENSE")).toBe("text");
});
