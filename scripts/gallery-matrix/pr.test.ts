import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertRunRevision, assertScenarioParity } from "./pr";

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

test("PR reports reject a matrix captured with different scenario controls", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-scenario-"));
  const manifest = join(root, "manifest.json");
  const results = join(root, "results");
  try {
    writeFileSync(manifest, JSON.stringify([{ id: "agent-pane.effort", params: { entry: "agent-pane.effort", variant: "high" } }]));
    mkdirSync(results);
    writeFileSync(
      join(results, "results.json"),
      JSON.stringify([
        {
          id: "agent-pane.effort",
          params: { entry: "agent-pane.effort", variant: "low" },
          revision: { sha: "head-a", source: "src/agent-pane/effort.gallery.tsx" },
        },
      ]),
    );
    expect(() => assertRunRevision(results, "head-a", "head", manifest)).toThrow(/scenario mismatch/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("PR reports reject shared IDs whose controls differ between sides", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-parity-"));
  const left = join(root, "left");
  const right = join(root, "right");
  try {
    mkdirSync(left);
    mkdirSync(right);
    writeFileSync(join(left, "results.json"), JSON.stringify([{ id: "same", params: { theme: "dark" } }]));
    writeFileSync(join(right, "results.json"), JSON.stringify([{ id: "same", params: { theme: "light" } }]));
    expect(() => assertScenarioParity(left, right)).toThrow(/scenario mismatch/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
