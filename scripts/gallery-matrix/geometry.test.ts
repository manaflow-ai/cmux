import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { lintGeometry, parseArtifact, parseConfig, validateScreenshot, type GeometryArtifact, type GeometryConfig, type GeometryRule } from "./geometry";
import { PNG } from "pngjs";
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

test("native evidence requires a native frame source", () => {
  const value = artifact();
  value.elements[0]!.kind = "native";
  expect(() => parseArtifact(value)).toThrow("native element a");
  for (const source of ["ax-frame", "view-frame"] as const) {
    value.elements[0]!.source = source;
    expect(parseArtifact(value).elements[0]!.source).toBe(source);
  }
});

test("evidence enums reject coerced strings before measurement", async () => {
  const value = artifact();
  value.capture.coordinateSpace = "screenshot-pixels";
  value.capture.deviceScaleFactor = 2;
  value.elements.forEach((element) => { element.style = { borderRadius: 4 }; });
  const radius: GeometryRule = { id: "radius", kind: "style-token", group: "icons", tolerancePx: 0, property: "borderRadius", tokensPx: [4] };
  expect((await lint(parseArtifact(value), [radius])).passed).toBe(false);
  for (const invalid of [["screenshot-pixels"], { toString: () => "screenshot-pixels" }, new String("screenshot-pixels")]) {
    expect(() => parseArtifact({ ...value, capture: { ...value.capture, coordinateSpace: invalid } })).toThrow("coordinateSpace");
  }
  for (const kind of ["native", "web"]) {
    for (const source of ["dom-rect", "ax-frame", "view-frame"]) {
      expect(() => parseArtifact({ ...value, elements: [{ ...value.elements[0], kind, source: [source] }] })).toThrow("source");
    }
  }
});

test("accepted debt needs a reason and a non-negative limit", () => {
  for (const debt of [{ maxDeltaPx: 1, reason: "" }, { maxDeltaPx: 1, reason: "  " }, { maxDeltaPx: -1, reason: "documented" }]) {
    expect(() => parseConfig({ ...config(), acceptedFindings: { existing: debt } })).toThrow("acceptedFindings");
  }
  expect(parseConfig({ ...config(), acceptedFindings: { existing: { maxDeltaPx: 0, reason: "documented" } } }).acceptedFindings?.existing?.maxDeltaPx).toBe(0);
});

test("font weight evidence is numeric and square geometry is valid", async () => {
  for (const fontWeight of [[400], new Number(400), "400", NaN, Infinity]) {
    const value = artifact(); Object.assign(value.elements[0]!, { style: { fontWeight } });
    expect(() => parseArtifact(value)).toThrow("fontWeight");
  }
  const value = artifact();
  value.elements.forEach((element) => { element.secondary = true; element.style = { fontWeight: 400, color: "#777", borderRadius: 0 }; });
  const radius: GeometryRule = { id: "square", kind: "style-token", group: "icons", tolerancePx: 0, property: "borderRadius", tokensPx: [0] };
  const secondary: GeometryRule = { id: "weight", kind: "secondary-text", group: "icons", tolerancePx: 0, colors: ["#777"], weights: [400] };
  expect((await lintGeometry([{ file: "fixture.json", artifact: parseArtifact(value) }], parseConfig(config([radius, secondary])))).passed).toBe(true);
  for (const token of [-1, NaN, Infinity]) expect(() => parseConfig(config([{ ...radius, tokensPx: [token] }]))).toThrow("tokensPx");
});

test("individual rules accept one element but still reject absent evidence", async () => {
  const value = artifact();
  value.elements = [{ ...value.elements[0]!, control: true, menuOpen: true, secondary: true, hoverRect: value.elements[0]!.rect, style: { borderRadius: 4, color: "#777", fontWeight: 400 } }];
  const rules: GeometryRule[] = [
    { id: "hover", kind: "hover-control-only", group: "icons", tolerancePx: 0, requireMenuOpen: true },
    { id: "radius", kind: "style-token", group: "icons", tolerancePx: 0, property: "borderRadius", tokensPx: [4] },
    { id: "secondary", kind: "secondary-text", group: "icons", tolerancePx: 0, colors: ["#777"], weights: [400] },
    { id: "source", kind: "required-source", group: "icons", tolerancePx: 0, requiredSource: "dom-rect" },
    { id: "inset", kind: "inset", group: "icons", containerGroup: "container", edge: "left", tolerancePx: 0, tokensPx: [10] },
  ];
  value.elements.push({ id: "container", kind: "web", source: "dom-rect", group: "container", rect: { x: 0, y: 0, width: 100, height: 100 } });
  expect((await lint(value, rules)).passed).toBe(true);
  expect((await lint(value, rules.map((entry) => ({ ...entry, minCount: 2 })))).findings).toHaveLength(5);
  const peerRules: GeometryRule[] = [rule(), { id: "size", kind: "peer-size", group: "icons", tolerancePx: 0, dimension: "width" }, { id: "spacing", kind: "spacing", group: "icons", tolerancePx: 0, axis: "y", tokensPx: [4] }, { id: "baseline", kind: "text-baseline", group: "icons", tolerancePx: 0 }];
  expect((await lint(value, peerRules)).findings.every((entry) => entry.message.includes("expected at least 2"))).toBe(true);
  value.elements = value.elements.filter((entry) => entry.group !== "icons");
  expect((await lint(value, rules)).findings).toHaveLength(5);
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

test("evidence flags reject non-booleans instead of treating them as truthy", () => {
  for (const flag of ["control", "secondary", "menuOpen"] as const) {
    for (const invalid of ["false", "true", 0, 1, null, {}, []]) {
      const value = artifact();
      Object.assign(value.elements[0]!, { [flag]: invalid });
      expect(() => parseArtifact(value)).toThrow(`${flag} must be a boolean`);
    }
    for (const valid of [false, true]) {
      const value = artifact();
      value.elements[0]![flag] = valid;
      expect(parseArtifact(value).elements[0]![flag]).toBe(valid);
    }
  }
  expect(parseArtifact(artifact()).elements[0]!.control).toBeUndefined();
});


test("rejects captures whose revision differs from the configured baseline", async () => {
  const value = artifact();
  value.revision.sha = "abcdef0123456789";
  const report = await lint(value);
  expect(report.passed).toBe(false);
  expect(report.errors).toContain(`fixture.geometry.json: capture revision abcdef0123456789 does not match config revision ${sha}`);
});

test("revision source must match the config and every artifact", async () => {
  const wrong = artifact(); wrong.revision.source = "different-fixture";
  const report = await lint(wrong);
  expect(report.passed).toBe(false);
  expect(report.errors).toContain('fixture.geometry.json: capture source "different-fixture" does not match config source "fixture"');

  const baseline = config();
  wrong.capture.theme = "dark";
  baseline.required.push({ caseId: "rows", engine: "chromium", theme: "dark" });
  const inputs = [{ file: "light.geometry.json", artifact: artifact() }, { file: "dark.geometry.json", artifact: wrong }];
  const mixed = await lintGeometry(inputs, baseline);
  expect(mixed.passed).toBe(false);
  expect(mixed.errors).toContain("dark.geometry.json: mixed capture revisions");
  // Matching each other is insufficient when both captures name the wrong source.
  inputs[0]!.artifact.revision.source = wrong.revision.source;
  const uniformlyWrong = await lintGeometry(inputs, baseline);
  expect(uniformlyWrong.passed).toBe(false);
  expect(uniformlyWrong.errors.filter((error) => error.includes("does not match config source"))).toHaveLength(2);
  for (const { artifact: value } of inputs) value.revision.source = baseline.revision.source;
  expect((await lintGeometry(inputs, baseline)).passed).toBe(true);
});

test("finding IDs preserve element boundaries", async () => {
  const first = artifact();
  first.elements[0]!.id = "a,b";
  first.elements[1]!.id = "c";
  first.elements[1]!.rect.x = 20;
  const second = artifact();
  second.elements[0]!.id = "a";
  second.elements[1]!.id = "b,c";
  second.elements[1]!.rect.x = 20;
  const firstReport = await lint(first);
  const secondReport = await lint(second);
  expect(firstReport.findings).toHaveLength(1);
  expect(secondReport.findings).toHaveLength(1);
  expect(firstReport.findings[0]!.id).not.toBe(secondReport.findings[0]!.id);
  const baseline = config();
  baseline.acceptedFindings = { [firstReport.findings[0]!.id]: { maxDeltaPx: 10, reason: "only the first pair" } };
  expect((await lintGeometry([{ file: "first.geometry.json", artifact: first }], baseline)).passed).toBe(true);
  expect((await lintGeometry([{ file: "second.geometry.json", artifact: second }], baseline)).passed).toBe(false);
  const otherTuple = structuredClone(first);
  first.capture.caseId = "rows:extra";
  otherTuple.capture.engine = "extra:chromium";
  expect((await lint(first)).findings[0]!.id).not.toBe((await lint(otherTuple)).findings[0]!.id);
});


test("capture tuples preserve colons for duplicate detection and crop lookup", async () => {
  const dir = mkdtempSync(join(process.cwd(), "geometry-capture-keys-"));
  try {
    const first = artifact(); first.capture.caseId = "rows:extra";
    const second = artifact(); second.capture.engine = "extra:chromium";
    const baseline = config(); baseline.required = [first.capture, second.capture];
    const inputs = [first, second].map((value, index) => {
      const png = new PNG({ width: 100, height: 100 });
      png.data.fill(index === 0 ? 17 : 231);
      const screenshot = join(dir, `${index}.png`);
      writeFileSync(screenshot, PNG.sync.write(png));
      value.capture.screenshot = screenshot;
      return { file: join(dir, `${index}.geometry.json`), artifact: value };
    });
    expect((await lintGeometry(inputs, baseline)).passed).toBe(true);
    const duplicate = await lintGeometry([...inputs, inputs[0]!], baseline);
    expect(duplicate.errors).toHaveLength(1);
    expect(duplicate.errors[0]).toContain('duplicate capture ["rows:extra","chromium","light"]');

    second.elements[1]!.rect.x += 2;
    const report = await lintGeometry(inputs, baseline, dir);
    expect(report.errors).toEqual([]);
    expect(report.findings).toHaveLength(1);
    const crop = PNG.sync.read(readFileSync(join(dir, report.findings[0]!.crop!)));
    expect(crop.data[0]).toBe(231);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("full-page screenshots may exceed viewport height", async () => {
  const dir = mkdtempSync(join(process.cwd(), "geometry-screenshot-"));
  try {
    const screenshot = join(dir, "full-page.png");
    const png = new PNG({ width: 100, height: 180 });
    writeFileSync(screenshot, PNG.sync.write(png));
    const value = artifact();
    value.capture.screenshot = screenshot;
    value.capture.screenshotSha256 = createHash("sha256").update(readFileSync(screenshot)).digest("hex");
    expect(await validateScreenshot("fixture.geometry.json", value)).toEqual([]);
    const narrow = new PNG({ width: 99, height: 180 });
    writeFileSync(screenshot, PNG.sync.write(narrow));
    value.capture.screenshotSha256 = createHash("sha256").update(readFileSync(screenshot)).digest("hex");
    expect((await validateScreenshot("fixture.geometry.json", value))[0]).toContain("do not cover viewport");
    writeFileSync(screenshot, PNG.sync.write(new PNG({ width: 100, height: 99 })));
    value.capture.screenshotSha256 = createHash("sha256").update(readFileSync(screenshot)).digest("hex");
    expect((await validateScreenshot("fixture.geometry.json", value))[0]).toContain("do not cover viewport");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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


test("CSS and scaled screenshot evidence produce identical measurements", async () => {
  const value = artifact();
  value.capture.deviceScaleFactor = 2;
  value.elements[1]!.rect.y = 34; // 8 CSS px gap
  value.elements = value.elements.map((element) => ({ ...element, control: true, hoverRect: { ...element.rect }, style: { baseline: 24, borderRadius: 4, gap: 8 } }));
  value.elements.push({ id: "container", kind: "web", source: "dom-rect", group: "container", rect: { x: 2, y: 2, width: 80, height: 80 } });
  const rules: GeometryRule[] = [rule(),
    { id: "size", kind: "peer-size", group: "icons", tolerancePx: 1, dimension: "width" },
    { id: "spacing", kind: "spacing", group: "icons", tolerancePx: 1, axis: "y", tokensPx: [8] },
    { id: "inset", kind: "inset", group: "icons", tolerancePx: 1, containerGroup: "container", edge: "left", tokensPx: [8] },
    { id: "radius", kind: "style-token", group: "icons", tolerancePx: 1, property: "borderRadius", tokensPx: [4] },
    { id: "gap", kind: "style-token", group: "icons", tolerancePx: 1, property: "gap", tokensPx: [8] },
    { id: "baseline", kind: "text-baseline", group: "icons", tolerancePx: 1 },
    { id: "hover", kind: "hover-control-only", group: "icons", tolerancePx: 1 }];
  const scaled = () => {
    const pixels = structuredClone(value);
    pixels.capture.coordinateSpace = "screenshot-pixels";
    for (const element of pixels.elements) {
      for (const rect of [element.rect, element.hoverRect]) if (rect) {
        for (const key of ["x", "y", "width", "height"] as const) rect[key] *= 2;
      }
      if (element.style) for (const key of ["baseline", "borderRadius", "gap"] as const) element.style[key]! *= 2;
    }
    return pixels;
  };
  expect((await lint(value, rules)).passed).toBe(true);
  expect((await lint(scaled(), rules)).passed).toBe(true);
  value.elements[1]!.rect.x += 2;
  value.elements[1]!.rect.y += 2;
  value.elements[1]!.rect.width += 2;
  value.elements[1]!.style = { baseline: 26, borderRadius: 6, gap: 10 };
  const before = structuredClone(value);
  const cssReport = await lint(value, rules);
  expect(cssReport.passed).toBe(false);
  expect((await lint(scaled(), rules)).findings).toEqual(cssReport.findings);
  expect(value).toEqual(before);
});

test("hover highlights may be contained but cannot overflow any control edge", async () => {
  const value = artifact();
  const rules: GeometryRule[] = [{ id: "hover", kind: "hover-control-only", group: "icons", tolerancePx: 1 }];
  value.elements = value.elements.map((element) => ({ ...element, control: true, hoverRect: { x: element.rect.x + 4, y: element.rect.y + 4, width: 8, height: 8 } }));
  expect((await lint(value, rules)).passed).toBe(true);
  const element = value.elements[0]!;
  for (const hoverRect of [
    { ...element.rect, x: element.rect.x - 2 },
    { ...element.rect, y: element.rect.y - 2 },
    { ...element.rect, x: element.rect.x + 1, width: element.rect.width + 1 },
    { ...element.rect, y: element.rect.y + 1, height: element.rect.height + 1 },
  ]) {
    element.hoverRect = hoverRect;
    expect((await lint(value, rules)).findings[0]!.message).toContain("beyond its control");
  }
  element.hoverRect = { x: element.rect.x - 1, y: element.rect.y - 1, width: element.rect.width + 2, height: element.rect.height + 2 };
  expect((await lint(value, rules)).passed).toBe(true);
});
