// l10n-allow-file: recorded tool fixtures, not shipped UI.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { mergeToolItem } from "../src/agent-session/acpmux/direct";
import { toolArtifacts } from "../src/agent-session/acpmux/conversation/writtenArtifacts";
import { artifactKind, type Artifact } from "../src/agent-session/acpmux/conversation/artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const page = "<title>Weather</title><p>Sunny</p>";
const call = (fields: Partial<Tool> = {}): Tool => ({
  id: "write-1",
  title: "Write",
  kind: "edit",
  status: "completed",
  ...fields,
});

type CodexChange = {
  path: string;
  type: "add" | "update" | "delete";
  additions?: number;
  deletions?: number;
  from?: string;
};

const normalizedCodex = (changes: CodexChange[], content: unknown[], id = "codex-change"): Tool => {
  const started = mergeToolItem(
    undefined,
    {
      title: `Edit ${changes.length} files`,
      kind: "edit",
      status: "in_progress",
      rawInput: { changes },
    },
    id,
    "",
  );
  return mergeToolItem(started, { status: "completed", content }, id, "done").tool!;
};

test.each(["Edit", "MultiEdit", "edit", "replace", "replace_in_file", "edit_file"])(
  "%s legacy unmarked edit snippets are not whole documents",
  (title) => {
    expect(toolArtifacts(call({ title, diffs: [{ path: "weather.html", newText: "<p>fragment</p>" }] }))).toEqual([]);
  },
);

const oldDoc = "<!doctype html>\n<html><body><h1>Weather</h1><p>Rain</p></body></html>";
const newDoc = "<!doctype html>\n<html><body><h1>Weather</h1><p>Sunny</p></body></html>";
const opened = (code: string, path = "weather.html"): Artifact[] => [{ kind: "html", lang: "html", code, path }];

test("a complete create opens its document", () => {
  expect(
    toolArtifacts(call({ title: "Write weather.html", diffs: [{ path: "weather.html", newText: newDoc }] })),
  ).toEqual(opened(newDoc));
});

test.each([
  ["Edit weather.html", { file_path: "weather.html", old_string: "<p>Rain</p>", new_string: "<p>Sunny</p>" }],
  ["edit", { filePath: "weather.html", oldString: "<p>Rain</p>", newString: "<p>Sunny</p>" }],
])("a complete %s whose diff is the whole old and new file opens it", (title, input) => {
  const recorded = call({
    title,
    inputSummary: JSON.stringify(input),
    diffs: [{ path: "weather.html", oldText: oldDoc, newText: newDoc }],
  });
  expect(toolArtifacts(recorded)).toEqual(opened(newDoc));
});

test.each(["replace", "replace_in_file"])("a complete %s opens the whole new document", (title) => {
  // No recorded input: the diff proves itself a whole file by being a whole HTML document.
  expect(toolArtifacts(call({ title, diffs: [{ path: "weather.html", oldText: oldDoc, newText: newDoc }] }))).toEqual(
    opened(newDoc),
  );
  // With its input recorded: a diff that is not the input's replacement is the file it left.
  const withInput = call({
    title,
    inputSummary: JSON.stringify({ file_path: "weather.html", old_string: "Rain", new_string: "Sunny" }),
    diffs: [{ path: "weather.html", oldText: "<p>Rain</p>", newText: "<p>Sunny</p><p>Warm</p>" }],
  });
  expect(toolArtifacts(withInput)).toEqual(opened("<p>Sunny</p><p>Warm</p>"));
});

test("an edit's replacement snippet stays closed, even when it is the shape of a document", () => {
  const snippet = { path: "weather.html", oldText: "<p>Rain</p>", newText: "<p>Sunny</p>" };
  expect(
    toolArtifacts(
      call({
        title: "Edit weather.html",
        inputSummary: JSON.stringify({
          file_path: "weather.html",
          old_string: "<p>Rain</p>",
          new_string: "<p>Sunny</p>",
        }),
        diffs: [snippet],
      }),
    ),
  ).toEqual([]);
  expect(
    toolArtifacts(
      call({
        title: "MultiEdit weather.html",
        inputSummary: JSON.stringify({
          file_path: "weather.html",
          edits: [
            { old_string: "Rain", new_string: "Sunny" },
            { old_string: "<html>", new_string: newDoc },
          ],
        }),
        diffs: [
          { path: "weather.html", oldText: "Rain", newText: "Sunny" },
          { path: "weather.html", oldText: "<html>", newText: newDoc },
        ],
      }),
    ),
  ).toEqual([]);
  // An unmarked legacy snippet with no input is not a document, and a marked fragment never is.
  expect(toolArtifacts(call({ title: "replace", diffs: [snippet] }))).toEqual([]);
  expect(
    toolArtifacts(call({ title: "Edit weather.html", diffs: [{ ...snippet, newText: newDoc, fragment: true }] })),
  ).toEqual([]);
});

test.each(["edit", "fileChange"])("%s completed whole ACP diffs need no harness-specific name", (kind) => {
  const recorded = call({
    title: "apply_patch",
    kind,
    diffs: [{ path: "weather.HTML", newText: page }],
  });
  expect(toolArtifacts(recorded)).toEqual([{ kind: "html", lang: "html", code: page, path: "weather.HTML" }]);
  expect(toolArtifacts({ ...recorded, status: "failed" })).toEqual([]);
  expect(toolArtifacts({ ...recorded, status: "in_progress" })).toEqual([]);
  expect(toolArtifacts({ ...recorded, kind: "read" })).toEqual([]);
});

test("a marked partial hunk never opens, but a confirmed whole write input does", () => {
  const partial = { path: "weather.html", newText: "<p>fragment</p>", fragment: true as const };
  expect(toolArtifacts(call({ title: "apply_patch", diffs: [partial] }))).toEqual([]);
  expect(
    toolArtifacts(
      call({
        diffs: [partial],
        inputSummary: JSON.stringify({ file_path: "weather.html", content: page }),
      }),
    ),
  ).toEqual([{ kind: "html", lang: "html", code: page, path: "weather.html" }]);
});

test.each([
  ["Write", "file_path"],
  ["write", "path"],
  ["write_file", "file_path"],
  ["writefile: weather.html", "path"],
  ["create_file: weather.html", "path"],
  ["write", "filePath"],
  ["write_file", "absolute_path"],
])("%s recorded whole inputs preserve canonical identity", (title, field) => {
  const recorded = call({
    title,
    inputSummary: JSON.stringify({ [field]: "./weather.html", content: page }),
    locations: [{ path: "./weather.html", canonical: "/project/weather.html" }],
  });
  expect(toolArtifacts(recorded)).toEqual([{ kind: "html", lang: "html", code: page, path: "/project/weather.html" }]);
});

test("full input is considered alongside other recorded diffs, once per file identity", () => {
  const recorded = call({
    diffs: [{ path: "other.html", newText: page }],
    inputSummary: JSON.stringify({ file_path: "weather.html", content: page }),
  });
  expect(toolArtifacts(recorded).map((artifact) => artifact.path)).toEqual(["other.html", "weather.html"]);
  expect(
    toolArtifacts({
      ...recorded,
      diffs: [{ path: "weather.html", newText: page }],
    }),
  ).toHaveLength(1);
});

test("a normalized multi-file record previews only its complete added HTML file", () => {
  const weather = "/repo/weather.html";
  const partial = "/repo/partial.html";
  const deleted = "/repo/deleted.html";
  const recorded = normalizedCodex(
    [
      { path: weather, type: "add", additions: 1, deletions: 0 },
      { path: partial, type: "update", additions: 1, deletions: 1 },
      { path: deleted, type: "delete", additions: 0, deletions: 1 },
    ],
    [
      { type: "diff", path: weather, newText: page },
      { type: "diff", path: partial, oldText: "old", newText: "<p>fragment</p>" },
      { type: "diff", path: deleted, oldText: page, newText: "" },
    ],
  );

  expect(toolArtifacts(recorded)).toEqual([{ kind: "html", lang: "html", code: page, path: weather }]);
});

test("an added file may match a diff through its normalized canonical path", () => {
  const recorded = normalizedCodex(
    [{ path: "/repo/real/weather.html", type: "add", additions: 1, deletions: 0 }],
    [
      {
        type: "diff",
        path: "/repo/link/weather.html",
        newText: page,
        _meta: { acpmux: { canonicalPath: "/repo/real/weather.html" } },
      },
    ],
    "codex-canonical",
  );

  expect(toolArtifacts(recorded)).toEqual([
    { kind: "html", lang: "html", code: page, path: "/repo/real/weather.html" },
  ]);
});

test("untrusted or partial add provenance never opens a document", () => {
  const cases: Array<{ changes: unknown[]; content: unknown[] }> = [
    {
      changes: [{ path: "/repo/weather.html", type: "add" }],
      content: [{ type: "diff", path: "/repo/weather.html", newText: page }],
    },
    {
      changes: [{ path: "/repo/weather.html", type: "update", additions: 1, deletions: 1 }],
      content: [{ type: "diff", path: "/repo/weather.html", newText: page }],
    },
    {
      changes: [{ path: "/repo/other.html", type: "add", additions: 1, deletions: 0 }],
      content: [{ type: "diff", path: "/repo/weather.html", newText: page }],
    },
    {
      changes: [{ path: "/repo/weather.html", type: "add", additions: 1, deletions: 0 }],
      content: [{ type: "diff", path: "/repo/weather.html", oldText: "old", newText: page }],
    },
    {
      changes: [{ path: "/repo/weather.html", type: "add", additions: 1, deletions: 0 }],
      content: [
        {
          type: "diff",
          path: "/repo/weather.html",
          newText: page,
          _meta: { acpmux: { fragment: true } },
        },
      ],
    },
  ];

  for (const [index, { changes, content }] of cases.entries()) {
    const recorded = normalizedCodex(changes as CodexChange[], content, `codex-malformed-${index}`);
    expect(toolArtifacts(recorded)).toEqual([]);
  }
});

test("multi-file add provenance scans recorded paths with bounded work", () => {
  const fileCount = 128;
  const changes = Array.from({ length: fileCount }, (_, index) => ({
    path: `/repo/file-${index}.html`,
    type: "add" as const,
    additions: 1,
    deletions: 0,
  }));
  const recorded = normalizedCodex(
    changes,
    changes.map(({ path }) => ({ type: "diff", path, newText: page })),
    "codex-bounded-work",
  );
  let pathReads = 0;
  recorded.diffs = recorded.diffs!.map((diff) => {
    const path = diff.path;
    return Object.defineProperty({ ...diff }, "path", {
      configurable: true,
      enumerable: true,
      get: () => {
        pathReads += 1;
        return path;
      },
    });
  });

  expect(toolArtifacts(recorded)).toHaveLength(fileCount);
  expect(pathReads).toBeLessThan(fileCount * 20);
});

test("empty bodies, unrelated files, malformed inputs and shell commands are not documents", () => {
  for (const recorded of [
    call({ diffs: [{ path: "weather.html", newText: " \n " }] }),
    call({ diffs: [{ path: "weather.html.bak", newText: page }] }),
    call({ inputSummary: "{" }),
    call({
      title: "Edit",
      inputSummary: JSON.stringify({ file_path: "weather.html", content: page }),
    }),
    call({
      title: "Bash",
      kind: "execute",
      inputSummary: JSON.stringify({ command: "cat > weather.html" }),
    }),
    call({
      title: "Edit",
      diffs: [{ path: "weather.html", oldText: "old", newText: page, fragment: true, fromInput: true }],
    }),
  ])
    expect(toolArtifacts(recorded)).toEqual([]);
});

test("completed immutable tool updates keep the cache current, including late content", () => {
  const started = mergeToolItem(
    undefined,
    {
      title: "Write",
      kind: "edit",
      status: "in_progress",
      rawInput: { file_path: "weather.html", content: page },
    },
    "write-1",
    "",
  );
  expect(toolArtifacts(started.tool!)).toEqual([]);
  const completed = mergeToolItem(started, { status: "completed" }, "write-1", "done");
  expect(completed.tool).not.toBe(started.tool);
  const first = toolArtifacts(completed.tool!);
  expect(first[0]?.code).toBe(page);
  expect(toolArtifacts(completed.tool!)).toBe(first);
  const changed = mergeToolItem(
    completed,
    { rawInput: { file_path: "weather.html", content: page + "<p>Updated</p>" } },
    "write-1",
    "",
  );
  expect(changed.tool).not.toBe(completed.tool);
  expect(toolArtifacts(changed.tool!)[0]?.code).toBe(page + "<p>Updated</p>");
  expect(toolArtifacts(completed.tool!)).toBe(first);
});

test.each(["html", "htm", "xhtml", "jsx", "tsx"])("%s fences keep A's shared HTML preview", (lang) => {
  expect(artifactKind(lang, page)).toBe("html");
});
