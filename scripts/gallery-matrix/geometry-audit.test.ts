import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseConfig, lintGeometry, type GeometryArtifact } from "./geometry";
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
      // Run the production CLI in a child: its process.exitCode must survive both stages.
      const child = Bun.spawn([process.execPath, join(import.meta.dir, "geometry-audit.ts"),
        "--gallery-dir", directory, "--output-dir", output, "--config", config, "--expected-sha", sha],
        { env: { ...process.env }, stdout: "pipe", stderr: "pipe" });
      const deadline = setTimeout(() => child.kill(), 20_000);
      const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
        .finally(() => clearTimeout(deadline));
      expect({ exitCode, geometryPassed: JSON.parse(readFileSync(join(output, "geometry-report", "geometry-report.json"), "utf8")).passed })
        .toEqual({ exitCode: scenario === "ready" ? 0 : 1, geometryPassed: true });
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
    schemaVersion: 1, revision: { sha: "a".repeat(40), source: "fixture" }, capture: { ...tuple, viewport: { width: 420, height: 900 }, deviceScaleFactor: 2, screenshot: "fixture.png", screenshotSha256: "0".repeat(64), coordinateSpace: "css-px" },
    elements: Array.from({ length: 7 }, (_, index) => ({ id: `top-block-label:${index}`, group: "top-block-label", source: "dom-rect", kind: "web", rect: { x: index < 5 ? 128 : 126, y: index * 28, width: 30, height: 18 } })),
  } as GeometryArtifact }));
  expect((await lintGeometry(captures, config)).passed).toBe(true);
  captures[0]!.artifact.elements[6]!.rect.x = 125;
  expect((await lintGeometry(captures, config)).passed).toBe(false);
});
