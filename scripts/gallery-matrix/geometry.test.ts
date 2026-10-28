import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { lintGeometry, parseArtifact, parseConfig, type GeometryArtifact, type GeometryConfig, type GeometryRule } from "./geometry";
import { main as lintMain } from "./geometry-lint";

const sha = "92c51f49804f48da9f46a86bbebea2bc11cd7f99";
const artifact = (): GeometryArtifact => ({ schemaVersion: 1, revision: { sha, source: "fixture" }, capture: { caseId: "rows", engine: "chromium", theme: "light", viewport: { width: 100, height: 100 }, deviceScaleFactor: 1, screenshot: "fixture.png", screenshotSha256: "0".repeat(64), coordinateSpace: "css-px" }, elements: [{ id: "a", kind: "web", source: "dom-rect", group: "icons", rect: { x: 10, y: 10, width: 16, height: 16 } }, { id: "b", kind: "web", source: "dom-rect", group: "icons", rect: { x: 10, y: 30, width: 16, height: 16 } }] });
const rule = (): GeometryRule => ({ id: "icon-column", kind: "peer-alignment", group: "icons", tolerancePx: 1, axis: "x", measure: "center" });
const config = (rules = [rule()]): GeometryConfig => ({ schemaVersion: 1, revision: { sha, source: "fixture" }, required: [{ caseId: "rows", engine: "chromium", theme: "light" }], rules });
const lint = (value = artifact(), rules = [rule()]) => lintGeometry([{ file: "fixture.geometry.json", artifact: value }], config(rules));

test("parses evidence and checks a shared icon column", async () => {
  expect(parseArtifact(artifact()).elements).toHaveLength(2);
  expect((await lint()).passed).toBe(true);
  const value = artifact(); value.elements[1]!.rect.x += 2;
  const report = await lint(value);
  expect(report.passed).toBe(false);
  expect(report.findings[0]!.deltaPx).toBe(2);
  expect(new Set(report.findings.map((finding) => finding.id)).size).toBe(report.findings.length);
});

test("missing evidence and unsupported text baselines cannot pass", async () => {
  expect((await lintGeometry([], config())).passed).toBe(false);
  const value = artifact(); value.elements = [];
  expect(() => parseArtifact(value)).toThrow("elements evidence");
  expect((await lint(artifact(), [{ id: "baseline", kind: "text-baseline", group: "icons", tolerancePx: 1 }])).findings[0]!.message).toContain("not a baseline");
  const missing = artifact(); missing.elements = missing.elements.map((element) => ({ ...element, group: "other" }));
  expect((await lint(missing)).passed).toBe(false);
});

test("native AX rules reject view frames", async () => {
  const value = artifact(); value.elements = value.elements.map((element) => ({ ...element, kind: "native", source: "view-frame" }));
  const report = await lint(value, [{ id: "native-column", kind: "required-source", group: "icons", tolerancePx: 0, requiredSource: "ax-frame" }]);
  expect(report.passed).toBe(false);
});

test("spacing tolerances are per rule and debt never hides missing evidence", async () => {
  const spacing: GeometryRule = { id: "row-gap", kind: "spacing", group: "icons", tolerancePx: 0.5, axis: "y", tokensPx: [4, 8] };
  expect((await lint(artifact(), [spacing])).passed).toBe(true);
  const value = artifact(); value.elements[1]!.rect.y += 1;
  const first = await lint(value, [spacing]);
  expect(first.findings[0]!.deltaPx).toBe(1);
  const baseline = config([spacing]); baseline.acceptedFindings = { [first.findings[0]!.id]: { maxDeltaPx: 1, reason: "existing debt" } };
  expect((await lintGeometry([{ file: "fixture.geometry.json", artifact: value }], baseline)).passed).toBe(true);
  value.elements[1]!.rect.y += 1;
  expect((await lintGeometry([{ file: "fixture.geometry.json", artifact: value }], baseline)).passed).toBe(false);
  value.elements = [];
  expect((await lintGeometry([{ file: "fixture.geometry.json", artifact: value }], baseline)).passed).toBe(false);
});

test("rejects malformed rules, duplicate IDs, invalid sizes and missing themes", async () => {
  expect(() => parseConfig({ ...config(), rules: [] })).toThrow("at least one");
  expect(() => parseConfig(config([{ ...rule(), kind: "ignored" } as never]))).toThrow("unknown rule");
  expect(() => parseConfig(config([{ id: "gap", kind: "spacing", group: "icons", axis: "y", tokensPx: [], tolerancePx: 1 }]))).toThrow("tokensPx");
  const value = artifact(); value.elements[1]!.id = "a";
  expect(() => parseArtifact(value)).toThrow("duplicate");
  value.capture.deviceScaleFactor = 0;
  expect(() => parseArtifact(value)).toThrow("positive");
  const baseline = config(); baseline.required.push({ caseId: "rows", engine: "chromium", theme: "dark" });
  expect((await lintGeometry([{ file: "fixture.geometry.json", artifact: artifact() }], baseline)).errors).toContain("missing required capture: rows:chromium:dark");
});

test("hover, insets, radii and secondary styles require their own evidence", async () => {
  const value = artifact();
  const rules: GeometryRule[] = [{ id: "hover", kind: "hover-control-only", group: "icons", tolerancePx: 0, requireMenuOpen: true }, { id: "radius", kind: "style-token", group: "icons", tolerancePx: 0.5, property: "borderRadius", tokensPx: [4, 8] }, { id: "secondary", kind: "secondary-text", group: "icons", tolerancePx: 0, colors: ["#777"], weights: [400] }];
  expect((await lint(value, rules)).findings).toHaveLength(6);
  value.elements = value.elements.map((element) => ({ ...element, control: true, hoverRect: element.rect, menuOpen: true, secondary: true, style: { borderRadius: 4, color: "#777", fontWeight: 400 } }));
  expect((await lint(value, rules)).passed).toBe(true);
  value.elements[0]!.hoverRect = { ...value.elements[0]!.rect, width: 100 };
  expect((await lint(value, rules)).findings[0]!.message).toContain("beyond its control");
});

test("CLI writes a failing report when screenshot evidence is missing", async () => {
  const dir = mkdtempSync(join(process.cwd(), "geometry-cli-"));
  try {
    const artifacts = join(dir, "artifacts"); const report = join(dir, "report");
    const configPath = join(dir, "config.json");
    const value = artifact(); value.capture.screenshot = "missing.png";
    mkdirSync(artifacts);
    writeFileSync(join(artifacts, "rows.geometry.json"), JSON.stringify(value));
    writeFileSync(configPath, JSON.stringify(config()));
    expect(await lintMain(["--artifact-dir", artifacts, "--config", configPath, "--report-dir", report, "--expected-sha", sha])).toBe(1);
    const result = JSON.parse(readFileSync(join(report, "geometry-report.json"), "utf8"));
    expect(result.errors.some((error: string) => error.includes("screenshot evidence unavailable"))).toBe(true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
