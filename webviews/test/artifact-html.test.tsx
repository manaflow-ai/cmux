import { expect, test } from "bun:test";
import { artifactKind } from "../src/agent-session/acpmux/conversation/artifactPreview";
import { outputArtifacts } from "../src/agent-session/acpmux/session-info/OutputsSection";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  artifactCanRender,
  artifactFrameURL,
  artifactGallery,
  artifactNeedsRun,
} from "../src/agent-session/acpmux/conversation/artifactSandbox";
import { uniqueArtifacts } from "../src/agent-session/acpmux/conversation/artifactDedupe";
import { writtenArtifacts } from "../src/agent-session/acpmux/conversation/writtenArtifacts";

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

test("artifact frames select only the native pane endpoints", () => {
  const before = Object.getOwnPropertyDescriptor(globalThis, "location");
  try {
    for (const [href, frame] of [
      ["cmux-agent://pane/index.html", "cmux-agent://render/artifact"],
      ["cmux-page://cmux.agent/", "cmux-page://cmux.agent/__artifact"],
      ["cmux-page://cmux.agent/index.html", "cmux-page://cmux.agent/__artifact"],
      ["cmux-page://cmux.agent.evil/", undefined],
      ["cmux-page://cmux.agent:1234/", undefined],
      ["cmux-page://user@cmux.agent/", undefined],
      ["cmux-page://cmux.settings/", undefined],
      ["https://cmux.agent/", undefined],
    ] as const) {
      Object.defineProperty(globalThis, "location", { configurable: true, value: new URL(href) });
      expect(artifactCanRender()).toBe(frame !== undefined);
      expect(artifactFrameURL()).toBe(frame);
    }
  } finally {
    if (before) Object.defineProperty(globalThis, "location", before);
    else Reflect.deleteProperty(globalThis, "location");
  }
});

test("artifact script consent conservatively catches parsed handlers and encoded javascript URLs", () => {
  for (const code of [
    '<svg/onload="for(;;){}"></svg>',
    '<a href="java&#x09;script:alert(1)">link</a>',
    '<a href="&#x6a;ava&#x73;cript&#x3a;alert(1)">link</a>',
    '<a href="java&Tab;script&colon;alert(1)">link</a>',
  ]) {
    expect(artifactNeedsRun(code)).toBe(true);
  }
  expect(artifactNeedsRun("<p>plain markup</p>")).toBe(false);
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
    // OpenCode and Gemini name the written file differently (toolPaths.ts).
    ["write", "filePath"],
    ["write_file", "absolute_path"],
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

test("a canonical full-diff create and raw-input overwrite stay one document", () => {
  const canonical = "/repo/counter.html";
  const latest = page.replace(">0<", ">10<");
  const writes = [
    ...rows({
      id: "create",
      title: "Write",
      kind: "edit",
      status: "completed",
      diffs: [{ path: "counter.html", canonical, newText: page }],
    }),
    ...rows({
      id: "overwrite",
      title: "Write",
      kind: "edit",
      status: "completed",
      inputPath: { path: "./counter.html", canonical },
      inputSummary: JSON.stringify({ file_path: "./counter.html", content: latest }),
    }),
  ];
  expect(writtenArtifacts(writes).map((artifact) => artifact.path)).toEqual([canonical, canonical]);
  expect(outputArtifacts(writes).map(({ artifact }) => [artifact.path, artifact.code])).toEqual([[canonical, latest]]);
});

test("the standalone opened-write version list drops repeated contents", () => {
  const write = (id: string, code: string) =>
    rows({ id, title: "Write", kind: "edit", status: "completed", diffs: [{ path: "counter.html", newText: code }] });
  const second = page.replace(">0<", ">1<");
  const opened = { kind: "html" as const, lang: "html", code: page, path: "counter.html" };
  const versions = uniqueArtifacts(
    writtenArtifacts([...write("a", page), ...write("b", second), ...write("c", page)]).filter(
      (item) => item.path === opened.path,
    ),
  );
  expect(versions.map((item) => item.code)).toEqual([page, second]);
});
