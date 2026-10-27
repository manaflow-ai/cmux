// l10n-allow-file: recorded tool fixtures, not shipped UI.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { mergeToolItem } from "../src/agent-session/acpmux/direct";
import { toolArtifacts } from "../src/agent-session/acpmux/conversation/writtenArtifacts";
import { artifactKind } from "../src/agent-session/acpmux/conversation/artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const page = "<title>Weather</title><p>Sunny</p>";
const call = (fields: Partial<Tool> = {}): Tool => ({
  id: "write-1",
  title: "Write",
  kind: "edit",
  status: "completed",
  ...fields,
});

test.each(["Edit", "MultiEdit", "edit", "replace", "replace_in_file", "edit_file"])(
  "%s legacy unmarked edit snippets are not whole documents",
  (title) => {
    expect(toolArtifacts(call({ title, diffs: [{ path: "weather.html", newText: "<p>fragment</p>" }] }))).toEqual([]);
  },
);

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
