import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseConfig, parseArtifact, lintGeometry, type GeometryArtifact } from "./geometry";
import { collectGeometry } from "./geometry-collector";
import { parseManifest } from "./runner";
import { captureEnvironment, configForCapture } from "./geometry-audit";

const baseline = JSON.parse(readFileSync(join(import.meta.dir, "geometry-baseline.json"), "utf8"));

test("baseline source is the gallery entry and run SHA is bound to the captured tip", () => {
  expect(baseline.revision.source).toBe("src/agent-session/acpmux/inspector/ChatInspector.gallery.tsx");
  expect(baseline.revision.sha).toMatch(/^[0-9a-f]{40}$/);
  const effective = configForCapture(baseline, "f".repeat(40));
  expect(effective.revision.sha).toBe("f".repeat(40));
  expect(effective.revision.source).toBe(baseline.revision.source);
  expect(baseline.revision.sha).not.toBe(effective.revision.sha);
});

test("capture environment requires an existing fleet or CI flag", () => {
  expect(captureEnvironment({})).toBe(false);
  expect(captureEnvironment({ CI: "false", CMUX_GALLERY_IN_VM: "0" })).toBe(false);
  expect(captureEnvironment({ CMUX_GALLERY_IN_VM: "1" })).toBe(true);
  expect(captureEnvironment({ CI: "true" })).toBe(true);
  expect(captureEnvironment({ CI: "1" })).toBe(true);
});

test("collector output parses with numeric computed font weights", async () => {
  const directory = mkdtempSync(join(tmpdir(), "geometry-collector-"));
  try {
    writeFileSync(join(directory, "capture.png"), Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64"));
    const page = { evaluate: async () => ({
      elements: [{ id: "label:0", kind: "web", source: "dom-rect", group: "label", rect: { x: 0, y: 0, width: 1, height: 1 }, style: { fontSize: 12, fontWeight: 400, color: "rgb(0, 0, 0)" } }],
      deviceScaleFactor: 1, viewport: { width: 1, height: 1 },
    }) } as any;
    const capture = { caseId: "fixture", engine: "chromium", theme: "light", screenshot: "capture.png", screenshotSha256: "", coordinateSpace: "css-px", viewport: { width: 1, height: 1 }, deviceScaleFactor: 1 };
    mkdirSync(directory, { recursive: true });
    const filename = await collectGeometry(page, [{ group: "label", selector: ".label" }], { schemaVersion: 1, revision: { sha: "a".repeat(40), source: "fixture" }, capture } as any, directory);
    const artifact = parseArtifact(JSON.parse(readFileSync(join(directory, filename), "utf8")));
    expect(artifact.elements[0]?.style?.fontWeight).toBe(400);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

const fleetOrCi = captureEnvironment();
for (const scenario of ["ready", "failed-play", "unready"] as const) {
  test.skipIf(!fleetOrCi)(`audit CLI preserves ${scenario} capture status when geometry passes`, async () => {
    const directory = mkdtempSync(join(tmpdir(), "geometry-audit-status-"));
    const sha = "a".repeat(40);
    const config = join(directory, "config.json");
    const output = join(directory, "output");
    writeFileSync(config, JSON.stringify({
      schemaVersion: 1, revision: { sha, source: "regression fixture" }, required: [{ caseId: "fixture", engine: "chromium", theme: "light" }],
      rules: [{ id: "column", kind: "peer-alignment", group: "label", axis: "x", measure: "start", tolerancePx: 0.5, minCount: 2, source: "dom-rect" }],
      cases: [{ id: "fixture", path_or_url: "frame.html", params: { colorScheme: "light", width: 200, height: 100 } }],
      selectors: { fixture: [{ group: "label", selector: ".label" }] },
    }));
    writeFileSync(join(directory, "frame.html"), `<!doctype html>
      <html data-gallery-ready="${scenario === "unready" ? "error" : "1"}" data-gallery-revision="${sha}" data-gallery-source="regression fixture">
      <body><div class="label">First</div><div class="label">Second</div><script>
        try {
          if (${JSON.stringify(scenario)} === "failed-play") throw new Error("fixture failed to play");
          window.cmuxGalleryPlayReport = { status: "pass", steps: [] };
        } catch (error) {
          window.cmuxGalleryPlayReport = { status: "fail", error: error.message, steps: [] };
        }
      </script></body></html>`);
    try {
      if (scenario === "unready") {
        // Simulate a rerun over a prior successful output. A failed capture
        // must not let these old artifacts satisfy the geometry lint.
        mkdirSync(output, { recursive: true });
        const stalePng = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");
        writeFileSync(join(output, "stale.png"), stalePng);
        writeFileSync(join(output, "stale.geometry.json"), JSON.stringify({
          schemaVersion: 1, revision: { sha, source: "regression fixture" },
          capture: { caseId: "fixture", engine: "chromium", theme: "light", viewport: { width: 1, height: 1 }, deviceScaleFactor: 1, screenshot: "stale.png", screenshotSha256: createHash("sha256").update(stalePng).digest("hex"), coordinateSpace: "css-px" },
          elements: [
            { id: "label:0", kind: "web", source: "dom-rect", group: "label", rect: { x: 0, y: 0, width: 1, height: 1 } },
            { id: "label:1", kind: "web", source: "dom-rect", group: "label", rect: { x: 0, y: 1, width: 1, height: 1 } },
          ],
        }));
      }
      // Run the production CLI in a child: play failures are diagnostic, while
      // geometry remains the gate.
      const child = Bun.spawn([process.execPath, join(import.meta.dir, "geometry-audit.ts"),
        "--gallery-dir", directory, "--output-dir", output, "--config", config, "--expected-sha", sha],
        { env: { ...process.env }, stdout: "pipe", stderr: "pipe" });
      const deadline = setTimeout(() => child.kill(), 20_000);
      const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
        .finally(() => clearTimeout(deadline));
      const report = JSON.parse(readFileSync(join(output, "geometry-report", "geometry-report.json"), "utf8"));
      expect({ exitCode, geometryPassed: report.passed, errors: report.errors })
        .toEqual({ exitCode: scenario === "unready" ? 1 : 0, geometryPassed: true, errors: [] });
      const [result] = JSON.parse(readFileSync(join(output, "results.json"), "utf8"));
      expect(result.ready).toBe(scenario === "unready" ? "error" : "1");
      expect(result.play.status).toBe(scenario === "failed-play" ? "fail" : "pass");
      expect(stdout).toContain("geometry: 1 captures");
      if (scenario === "unready") expect(stderr).toContain("not ready");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }, 30_000);
}

test("collector assigns unique IDs across repeated selections", async () => {
  const directory = mkdtempSync(join(tmpdir(), "geometry-collector-ids-"));
  try {
    writeFileSync(join(directory, "capture.png"), Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64"));
    const page = { evaluate: async () => ({
      elements: [
        { id: "label:0", kind: "web", source: "dom-rect", group: "label", rect: { x: 0, y: 0, width: 1, height: 1 } },
        { id: "label:0", kind: "web", source: "dom-rect", group: "label", rect: { x: 1, y: 0, width: 1, height: 1 } },
      ], deviceScaleFactor: 1, viewport: { width: 2, height: 1 },
    }) } as any;
    const filename = await collectGeometry(page, [{ group: "label", selector: ".all" }, { group: "label", selector: ".secondary" }], { schemaVersion: 1, revision: { sha: "a".repeat(40), source: "fixture" }, capture: { caseId: "fixture", engine: "chromium", theme: "light", screenshot: "capture.png" } } as any, directory);
    const artifact = parseArtifact(JSON.parse(readFileSync(join(directory, filename), "utf8")));
    expect(artifact.elements.map((element) => element.id)).toEqual(["label:0", "label:1"]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("audit baseline pairs both appearances and every required group has a selector", () => {
  const config = parseConfig(baseline);
  const cases = parseManifest(baseline.cases);
  expect(config.required).toHaveLength(2);
  expect(new Set(config.required.map((value) => value.theme))).toEqual(new Set(["light", "dark"]));
  for (const tuple of config.required) {
    expect(cases.find((value) => value.id === tuple.caseId)?.params?.colorScheme).toBe(tuple.theme);
    for (const rule of config.rules) expect(baseline.selectors[tuple.caseId].some((selection: { group: string }) => selection.group === rule.group)).toBe(true);
  }
});

test("measured two-pixel debt is bounded and missing Context/Connectors cannot hide it", async () => {
  const config = parseConfig(baseline);
  const captures = config.required.map((tuple) => ({ file: "fixture", artifact: {
    schemaVersion: 1, revision: { sha: baseline.revision.sha, source: baseline.revision.source }, capture: { ...tuple, viewport: { width: 420, height: 900 }, deviceScaleFactor: 2, screenshot: "fixture.png", screenshotSha256: "0".repeat(64), coordinateSpace: "css-px" },
    elements: Array.from({ length: 7 }, (_, index) => ({ id: `top-block-label:${index}`, group: "top-block-label", source: "dom-rect", kind: "web", rect: { x: index < 5 ? 128 : 126, y: index * 28, width: 30, height: 18 } })),
  } as GeometryArtifact }));
  const measured = await lintGeometry(captures, config);
  expect({ passed: measured.passed, errors: measured.errors }).toEqual({ passed: true, errors: [] });
  captures[0]!.artifact.elements[6]!.rect.x = 125;
  expect((await lintGeometry(captures, config)).passed).toBe(false);
});
