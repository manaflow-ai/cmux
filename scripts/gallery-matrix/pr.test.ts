import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertRunRevision } from "./pr";

test("PR reports reject a matrix captured from the wrong head", () => {
  const dir = mkdtempSync(join(tmpdir(), "gallery-pr-provenance-"));
  try {
    writeFileSync(
      join(dir, "results.json"),
      JSON.stringify([{ id: "agent-pane.effort", revision: { sha: "head-a", source: "src/agent-pane/effort.gallery.tsx" } }]),
    );
    expect(() => assertRunRevision(dir, "head-b", "head")).toThrow(/provenance mismatch/);
    expect(() => assertRunRevision(dir, "head-a", "head")).not.toThrow();
    writeFileSync(join(dir, "results.json"), JSON.stringify([{ id: "agent-pane.effort", revision: { sha: "head-a" } }]));
    expect(() => assertRunRevision(dir, "head-a", "head")).toThrow(/provenance mismatch/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
