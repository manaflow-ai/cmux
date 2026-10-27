import { expect, test } from "bun:test";
import { artifactKind } from "../src/agent-session/acpmux/conversation/artifactPreview";
import { outputArtifacts } from "../src/agent-session/acpmux/inspector/OutputsSection";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { artifactGallery } from "../src/agent-session/acpmux/conversation/artifactSandbox";

const page = '<title>Counter</title><button onclick="this.textContent++">0</button>';
const rows = (tool: NonNullable<AcpmuxActivity["tool"]>): AcpmuxRow[] => [
  { id: tool.id, version: 1, at: 0, kind: "activity", items: [{ kind: "tool", text: "", tool }] },
];

test("offline artifacts use the sandbox in dev and built gallery frame routes only", () => {
  const before = Object.getOwnPropertyDescriptor(globalThis, "location");
  try {
    for (const [path, expected] of [
      ["/gallery/frame.html?entry=agent-pane.artifact-panel", true],
      ["/frame.html?entry=agent-pane.artifact-panel", true],
      ["/frame.html", false],
      ["/index.html?entry=agent-pane.artifact-panel", false],
    ] as const) {
      Object.defineProperty(globalThis, "location", {
        configurable: true,
        value: new URL(path, "https://gallery.test"),
      });
      expect(artifactGallery()).toBe(expected);
    }
  } finally {
    if (before) Object.defineProperty(globalThis, "location", before);
    else Reflect.deleteProperty(globalThis, "location");
  }
});

test("JSX fences use the HTML artifact surface", () => {
  expect(artifactKind("jsx", "export default () => <button>Hi</button>")).toBe("html");
  expect(artifactKind("tsx", "export default () => <svg />")).toBe("html");
});

for (const title of ["Write", "apply_patch", "write", "write_file"])
  test(`${title}: a completed full HTML write opens from Outputs`, () => {
    const tool = {
      id: title,
      title,
      kind: "edit",
      status: "completed",
      diffs: [{ path: "counter.html", newText: page }],
    };
    expect(outputArtifacts(rows(tool)).map(({ artifact }) => artifact.code)).toEqual([page]);
    expect(outputArtifacts(rows({ ...tool, status: "failed" }))).toEqual([]);
    expect(outputArtifacts(rows({ ...tool, status: "in_progress" }))).toEqual([]);
    expect(
      outputArtifacts(
        rows({ ...tool, diffs: [{ path: "counter.html", newText: page, oldText: "x", fragment: true }] }),
      ),
    ).toEqual([]);
  });

test("full write inputs are detected without reading the file; malformed inputs and hunks are not", () => {
  for (const [title, field] of [
    ["Write", "file_path"],
    ["write", "path"],
    ["write_file", "file_path"],
  ]) {
    const tool = {
      id: title!,
      title: title!,
      kind: "edit",
      status: "completed",
      inputSummary: JSON.stringify({ [field!]: "counter.HTML", content: page }),
    };
    expect(outputArtifacts(rows(tool))[0]?.artifact.code).toBe(page);
    expect(outputArtifacts(rows({ ...tool, inputSummary: '{"content":' }))).toEqual([]);
    expect(outputArtifacts(rows({ ...tool, title: "Edit" }))).toEqual([]);
  }
});

test("Outputs uses the latest write per path, keeping same-title files distinct", () => {
  const write = (path: string, code: string) =>
    rows({ id: code, title: "Write", kind: "edit", status: "completed", diffs: [{ path, newText: code }] });
  const latest = page.replace(">0<", ">10<");
  const outputs = outputArtifacts([...write("a.html", page), ...write("b.html", page), ...write("a.html", latest)]);
  expect(outputs.map(({ artifact }) => [artifact.path, artifact.code])).toEqual([
    ["a.html", latest],
    ["b.html", page],
  ]);
});
