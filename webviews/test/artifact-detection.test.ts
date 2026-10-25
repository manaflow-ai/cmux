// l10n-allow-file: artifact regression fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { artifactKind } from "../src/agent-session/acpmux/conversation/artifactPreview";
import { artifactVersions, chatDocuments } from "../src/agent-session/acpmux/conversation/artifactVersions";
import { activity, assistant, tool } from "../src/gallery/fixtures/acpmux";

const page = (version: number) => `<title>Weather</title><p>Version ${version}</p>`;
const written = (name: string, path: string, code: string, extra = {}) =>
  activity([tool(name, "edit", "completed", { diffs: [{ path, newText: code, ...extra }] })], 2);

test("finished fences normalize HTML, SVG and JSX, but incomplete fences stay out", () => {
  expect(String(artifactKind("jsx", "export default () => <h1>Weather</h1>"))).toBe("jsx");
  expect(chatDocuments(["```html\n<p>incomplete"])).toEqual([]);
  expect(
    chatDocuments(["```html\n<p>ok</p>\n```", "```svg\n<svg/>\n```", "```jsx\nconst App = () => <div/>;\n```"]).map(
      (artifact) => String(artifact.kind),
    ),
  ).toEqual(["html", "svg", "jsx"]);
});

test.each(["Write", "apply_patch", "write", "write_file"])("%s completed full HTML writes become documents", (name) => {
  const rows = [written(name, "weather.html", page(1))];
  expect(chatDocuments(rows)).toMatchObject([{ kind: "html", lang: "html", code: page(1), path: "weather.html" }]);
});

test("versions follow canonical file identity across title changes, without merging equal-title files", () => {
  const rows = [
    written("Write", "./weather.html", page(1), { canonical: "/project/weather.html" }),
    written("write_file", "other.html", page(1)),
    written("write", "weather.html", page(2), { canonical: "/project/weather.html" }),
    written("apply_patch", "weather.html", "<title>Forecast</title><p>Version 3</p>", {
      canonical: "/project/weather.html",
    }),
  ];
  const found = chatDocuments(rows);
  expect(found).toHaveLength(4);
  expect(artifactVersions(rows, found[3]!).map((version) => version.code)).toEqual([
    page(1),
    page(2),
    "<title>Forecast</title><p>Version 3</p>",
  ]);
});

test("failed/running writes, reads, fragments, deletions and streaming replies are not documents", () => {
  const rows = [
    ...["failed", "in_progress"].map((status) =>
      activity([tool("Write", "edit", status, { diffs: [{ path: "x.html", newText: page(1) }] })], 1),
    ),
    activity([tool("Read", "read", "completed", { diffs: [{ path: "x.html", newText: page(1) }] })], 1),
    written("Edit", "x.html", "<p>fragment</p>", { fragment: true }),
    written("Edit", "x.html", "<p>unmarked legacy fragment</p>"),
    written("edit", "x.html", "<p>pi edit fragment</p>"),
    written("Write", "x.html", ""),
    written("Write", "x.html.bak", page(1)),
    assistant("```html\n<p>streaming</p>\n```", 1, { streaming: true }),
  ];
  expect(chatDocuments(rows)).toEqual([]);
});

test.each([
  ["Claude", "Write", { file_path: "weather.html", content: page(1) }],
  ["pi", "write", { path: "weather.html", content: page(1) }],
  ["Gemini", "write_file", { file_path: "weather.html", content: page(1) }],
] as const)("%s full write input normalizes without reading the file", (_harness, name, input) => {
  const rows = [activity([tool(name, "edit", "completed", { inputSummary: JSON.stringify(input) })], 1)];
  expect(chatDocuments(rows)).toMatchObject([{ kind: "html", code: page(1), path: "weather.html" }]);
});

test("write input overwrites keep versions even when their diff is an unknown-old fragment", () => {
  const rows = [1, 2, 3].map((version) =>
    activity(
      [
        tool("Write", "edit", "completed", {
          inputSummary: JSON.stringify({ file_path: "weather.html", content: page(version) }),
          diffs: [{ path: "weather.html", newText: page(version), fragment: true }],
        }),
      ],
      4 - version,
    ),
  );
  const found = chatDocuments(rows);
  expect(artifactVersions(rows, found[2]!).map((item) => item.code)).toEqual([page(1), page(2), page(3)]);
});

test("malformed and unrelated input cannot supply a written artifact", () => {
  const rows = [
    activity([tool("Write", "edit", "completed", { inputSummary: "{" })], 1),
    activity(
      [
        tool("Edit", "edit", "completed", {
          inputSummary: JSON.stringify({ file_path: "weather.html", content: page(1) }),
        }),
      ],
      1,
    ),
    activity(
      [
        tool("Write", "edit", "failed", {
          inputSummary: JSON.stringify({ file_path: "weather.html", content: page(1) }),
        }),
      ],
      1,
    ),
  ];
  expect(chatDocuments(rows)).toEqual([]);
});

test("ACP tool updates retain full inputs until completion and expose Codex full diffs", async () => {
  const { mergeToolItem } = await import("../src/agent-session/acpmux/direct");
  for (const [title, rawInput] of [
    ["Write", { file_path: "weather.html", content: page(1) }],
    ["write", { path: "weather.html", content: page(1) }],
    ["write_file", { file_path: "weather.html", content: page(1) }],
  ] as const) {
    const started = mergeToolItem(undefined, { title, kind: "edit", status: "in_progress", rawInput }, "write-1", "");
    expect(chatDocuments([activity([started], 1)])).toEqual([]);
    const completed = mergeToolItem(started, { status: "completed" }, "write-1", "done");
    expect(chatDocuments([activity([completed], 1)]).map((item) => item.code)).toEqual([page(1)]);
  }
  const codex = mergeToolItem(
    undefined,
    {
      title: "apply_patch",
      kind: "edit",
      status: "completed",
      content: [{ type: "diff", path: "weather.html", newText: page(1) }],
    },
    "patch-1",
    "done",
  );
  expect(chatDocuments([activity([codex], 1)]).map((item) => item.code)).toEqual([page(1)]);
});

test("the gallery fixture has three navigable HTML versions", async () => {
  const { default: entry } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel.gallery");
  const rows = entry.variants["html-three-versions"]!.snapshot.rows;
  const documents = chatDocuments(rows);
  expect(documents).toHaveLength(3);
  expect(artifactVersions(rows, documents[0]!)).toEqual(documents);
});

test("Inspector Outputs discovers written files without collapsing identical contents at different paths", async () => {
  const { outputArtifacts } = await import("../src/agent-session/acpmux/inspector/OutputsSection");
  const rows = [written("Write", "one.html", page(1)), written("write_file", "two.html", page(1))];
  const outputs = outputArtifacts(rows);
  expect(outputs.map((item) => item.artifact.path)).toEqual(["one.html", "two.html"]);
  expect(artifactVersions(rows, outputs[1]!.artifact)).toEqual([outputs[1]!.artifact]);
});
