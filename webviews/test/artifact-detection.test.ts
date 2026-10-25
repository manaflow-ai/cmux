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
  expect(chatDocuments(rows as unknown as string[])).toMatchObject([
    { kind: "html", lang: "html", code: page(1), path: "weather.html" },
  ]);
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
  const found = chatDocuments(rows as unknown as string[]);
  expect(found).toHaveLength(4);
  expect(artifactVersions(rows as unknown as string[], found[3]!).map((version) => version.code)).toEqual([
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
    written("Write", "x.html", ""),
    written("Write", "x.html.bak", page(1)),
    assistant("```html\n<p>streaming</p>\n```", 1, { streaming: true }),
  ];
  expect(chatDocuments(rows as unknown as string[])).toEqual([]);
});
