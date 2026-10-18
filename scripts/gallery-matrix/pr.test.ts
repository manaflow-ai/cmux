import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertRunRevision, assertScenarioParity, comparisonReceipt } from "./pr";
import { scenarioFingerprint } from "./scenario";

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

test("PR reports reject failed or partial capture receipts", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-receipt-quality-"));
  const manifest = join(root, "manifest.json");
  const results = join(root, "results");
  try {
    writeFileSync(manifest, JSON.stringify([{ id: "head", path_or_url: "frame.html", params: { entry: "head" } }]));
    mkdirSync(results);
    writeFileSync(
      join(results, "results.json"),
      JSON.stringify([{ id: "head", params: { entry: "head" }, revision: { sha: "head-a", source: "src/head.gallery.tsx" } }]),
    );
    writeFileSync(
      join(results, "receipt.json"),
      JSON.stringify({ captureId: "failed", capturedAt: "2026-10-18T00:00:00Z", scenario: { count: 1, fingerprint: "0".repeat(64) }, results: { count: 0, expected: 1, status: "partial" }, quality: "fail" }),
    );
    expect(() => assertRunRevision(results, "head-a", "head", manifest)).toThrow(/not complete quality evidence/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("PR reports require a receipt when a union capture manifest is supplied", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-missing-receipt-"));
  const manifest = join(root, "manifest.json");
  const captureManifest = join(root, "capture-manifest.json");
  const results = join(root, "results");
  try {
    const cases = [{ id: "head", path_or_url: "frame.html", params: { entry: "head" } }];
    writeFileSync(manifest, JSON.stringify(cases));
    writeFileSync(captureManifest, JSON.stringify(cases));
    mkdirSync(results);
    writeFileSync(
      join(results, "results.json"),
      JSON.stringify([{ id: "head", params: { entry: "head" }, revision: { sha: "head-a", source: "src/head.gallery.tsx" } }]),
    );
    expect(() => assertRunRevision(results, "head-a", "head", manifest, captureManifest)).toThrow(/capture receipt/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("PR reports allow union captures to include cases outside a side manifest", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-union-"));
  const manifest = join(root, "manifest.json");
  const results = join(root, "results");
  try {
    writeFileSync(manifest, JSON.stringify([{ id: "head", params: { entry: "head", variant: "a" } }]));
    mkdirSync(results);
    writeFileSync(
      join(results, "results.json"),
      JSON.stringify([
        { id: "head", params: { entry: "head", variant: "a" }, revision: { sha: "head-a", source: "src/head.gallery.tsx" } },
        { id: "base-only", params: { entry: "base-only", variant: "a" }, revision: { sha: "head-a", source: "src/base.gallery.tsx" } },
      ]),
    );
    expect(() => assertRunRevision(results, "head-a", "head", manifest)).not.toThrow();
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

test("PR reports reject shared IDs whose manifest routes differ", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-route-parity-"));
  const left = join(root, "left");
  const right = join(root, "right");
  const leftManifest = join(root, "left.json");
  const rightManifest = join(root, "right.json");
  try {
    mkdirSync(left);
    mkdirSync(right);
    writeFileSync(join(left, "results.json"), JSON.stringify([{ id: "same", params: { entry: "same" } }]));
    writeFileSync(join(right, "results.json"), JSON.stringify([{ id: "same", params: { entry: "same" } }]));
    writeFileSync(leftManifest, JSON.stringify([{ id: "same", path_or_url: "frame.html", params: { entry: "same" } }]));
    writeFileSync(rightManifest, JSON.stringify([{ id: "same", path_or_url: "other-frame.html", params: { entry: "same" } }]));
    expect(() => assertScenarioParity(left, right, "base/head", leftManifest, rightManifest)).toThrow(/manifest mismatch/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("PR receipt validation accepts equivalent manifest ordering", () => {
  const root = mkdtempSync(join(tmpdir(), "gallery-pr-ordering-"));
  const manifest = join(root, "manifest.json");
  const results = join(root, "results");
  try {
    const ordered = [
      { id: "a", path_or_url: "frame.html", params: { entry: "a" } },
      { id: "b", path_or_url: "frame.html", params: { entry: "b" } },
    ];
    const reversed = [...ordered].reverse();
    writeFileSync(manifest, JSON.stringify(ordered));
    mkdirSync(results);
    writeFileSync(join(results, "results.json"), JSON.stringify(ordered.map((item) => ({ id: item.id, params: item.params, revision: { sha: "head-a", source: `src/${item.id}.gallery.tsx` } }))));
    writeFileSync(join(results, "receipt.json"), JSON.stringify({ captureId: "ordered", capturedAt: "2026-10-18T00:00:00Z", scenario: { count: 2, fingerprint: scenarioFingerprint(reversed) }, results: { count: 2, expected: 2, status: "complete" }, quality: "pass", revisions: { shas: ["head-a"], sources: ["src/a.gallery.tsx", "src/b.gallery.tsx"] } }));
    expect(() => assertRunRevision(results, "head-a", "head", manifest)).not.toThrow();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a comparison records candidate evidence without claiming current or superseding its baseline", () => {
  const receipt = comparisonReceipt(
    { captureId: "base-capture", scenarioFingerprint: "scenario-a" },
    { captureId: "head-capture", scenarioFingerprint: "scenario-a", quality: "pass" },
    undefined,
    { base: "base-a", head: "head-a" },
  );
  expect(receipt).toMatchObject({
    freshness: { status: "unverified" },
    supersession: { status: "not-claimed", baselineCaptureId: "base-capture" },
    candidate: { captureId: "head-capture", role: "candidate", sha: "head-a" },
    baseline: { captureId: "base-capture", role: "baseline", sha: "base-a" },
  });
  expect(receipt).not.toHaveProperty("current");
  expect(receipt).not.toHaveProperty("supersedes");
  expect(receipt.history.map((item) => item.role)).toEqual(["baseline", "candidate"]);
});

test("comparison receipts verify freshness only when the observed live head matches", () => {
  const base = { captureId: "base", scenarioFingerprint: "s" };
  const head = { captureId: "head", scenarioFingerprint: "s" };
  expect(comparisonReceipt(base, head, undefined, { base: "base-sha", head: "head-sha" }, "head-sha").freshness).toMatchObject({ status: "verified", observedSha: "head-sha" });
  expect(comparisonReceipt(base, head, undefined, { base: "base-sha", head: "head-sha" }, "other-sha").freshness).toMatchObject({ status: "mismatch", observedSha: "other-sha" });
});
