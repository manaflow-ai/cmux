import { expect, test } from "bun:test";
import { artifactKind } from "../src/agent-session/acpmux/conversation/artifactPreview";
import { outputArtifacts } from "../src/agent-session/acpmux/inspector/OutputsSection";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const page = '<title>Counter</title><button onclick="this.textContent++">0</button>';
const rows = (tool: NonNullable<AcpmuxActivity["tool"]>): AcpmuxRow[] => [
  { kind: "activity", items: [{ kind: "tool", text: "", tool }] } as AcpmuxRow,
];

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
