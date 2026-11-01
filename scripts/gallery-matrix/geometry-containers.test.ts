import { expect, test } from "bun:test";
import { lintGeometry, parseConfig, type GeometryArtifact, type GeometryConfig, type GeometryElement, type GeometryRule } from "./geometry";

const node = (id: string, group: string, x: number, y: number, width: number, height: number, containerId?: string, part?: string): GeometryElement => ({ id, group, rect: { x, y, width, height }, source: "dom-rect", kind: "web", containerId, part });
const capture = (elements: GeometryElement[]): GeometryArtifact => ({ schemaVersion: 1, revision: { sha: "a".repeat(40), source: "synthetic negative-regression fixture" }, capture: { caseId: "fixture", engine: "chromium", theme: "light", viewport: { width: 400, height: 400 }, deviceScaleFactor: 1, screenshot: "fixture.png", screenshotSha256: "0".repeat(64), coordinateSpace: "css-px" }, elements });
const config = (rules: GeometryRule[]): GeometryConfig => ({ schemaVersion: 1, revision: { sha: "a".repeat(40), source: "synthetic negative-regression fixture" }, required: [{ caseId: "fixture", engine: "chromium", theme: "light" }], rules });
const check = (elements: GeometryElement[], rules: GeometryRule[]) => lintGeometry([{ file: "fixture", artifact: capture(elements) }], config(rules));

const rowRules: GeometryRule[] = [
  { id: "trailing-column", kind: "peer-alignment", group: "indicators", axis: "x", measure: "end", tolerancePx: 0.5 },
  { id: "row-center", kind: "container-center", group: "indicators", containerGroup: "rows", axis: "y", tolerancePx: 0.5 },
  { id: "row-exclusive", kind: "exclusive-parts", group: "indicators", containerGroup: "rows", parts: ["spinner", "control"], tolerancePx: 0 },
];
const rows = () => [node("workspace", "rows", 0, 0, 300, 28), node("group", "rows", 16, 28, 284, 28), node("inner-tab", "rows", 32, 56, 268, 28), node("workspace-dot", "indicators", 280, 7, 14, 14, "workspace", "spinner"), node("group-dot", "indicators", 280, 35, 14, 14, "group", "control"), node("inner-dot", "indicators", 280, 63, 14, 14, "inner-tab", "spinner")];

test("all nesting depths share one trailing column and each row's center", async () => {
  expect((await check(rows(), rowRules)).passed).toBe(true);
  for (const id of ["workspace-dot", "group-dot", "inner-dot"]) {
    const elements = rows(); elements.find((element) => element.id === id)!.rect.x -= 2;
    expect((await check(elements, rowRules)).findings.some((finding) => finding.rule === "trailing-column" && finding.deltaPx === 2)).toBe(true);
  }
  const elements = rows(); elements[5]!.rect.y += 1;
  expect((await check(elements, rowRules)).findings.some((finding) => finding.rule === "row-center" && finding.deltaPx === 1)).toBe(true);
});

test("spinner/control exclusivity is per row, including newly nested instances", async () => {
  const elements = rows(); elements.push(node("new-inner", "rows", 48, 84, 252, 28), node("new-spin", "indicators", 280, 91, 14, 14, "new-inner", "spinner"), node("new-close", "indicators", 280, 91, 14, 14, "new-inner", "control"));
  expect((await check(elements, rowRules)).findings.some((finding) => finding.rule === "row-exclusive" && finding.elementIds.includes("new-inner"))).toBe(true);
});

test("every header aligns its own action boxes without comparing different rows", async () => {
  const elements = [node("header-a", "headers", 0, 0, 300, 32), node("header-b", "headers", 0, 100, 300, 32), node("copy-a", "actions", 200, 4, 60, 24, "header-a"), node("close-a", "actions", 270, 4, 24, 24, "header-a"), node("copy-b", "actions", 200, 104, 60, 24, "header-b"), node("close-b", "actions", 270, 104, 24, 24, "header-b")];
  const rules: GeometryRule[] = [{ id: "action-center", kind: "container-peer-alignment", group: "actions", containerGroup: "headers", axis: "y", measure: "center", tolerancePx: 0.5 }];
  expect((await check(elements, rules)).passed).toBe(true);
  elements[4]!.rect.y -= 2;
  expect((await check(elements, rules)).findings[0]!.deltaPx).toBe(2);
  elements.pop();
  expect((await check(elements, rules)).findings.some((finding) => finding.message.includes("missing peers"))).toBe(true);
});

test("unknown parents, missing containers, unclassified parts and mislabeled AX fail", async () => {
  const elements = rows(); elements[5]!.containerId = "unknown";
  expect((await check(elements, rowRules)).passed).toBe(false);
  expect((await check(elements.filter((element) => element.group !== "rows"), rowRules)).passed).toBe(false);
  elements[5]!.containerId = "inner-tab"; elements[5]!.part = undefined;
  expect((await check(elements, rowRules)).findings.some((finding) => finding.message.includes("unknown visible part"))).toBe(true);
  const axRule = { ...rowRules[1]!, source: "ax-frame" } as GeometryRule;
  expect((await check(rows(), [axRule])).passed).toBe(false);
});

test("malformed container rules never turn into a silent no-op", () => {
  expect(() => parseConfig(config([{ ...rowRules[1]!, axis: "z" } as never]))).toThrow("axis");
  expect(() => parseConfig(config([{ ...rowRules[2]!, parts: ["spinner"] } as never]))).toThrow("distinct");
  expect(() => parseConfig(config([{ ...rowRules[1]!, containerGroup: "" } as never]))).toThrow("containerGroup");
});

test("unsupported text-baseline coverage remains explicit in the CI report", async () => {
  const baseline = config(rowRules); baseline.coverageGaps = ["Text range bounds are not measured glyph baselines."];
  const result = await lintGeometry([{ file: "fixture", artifact: capture(rows()) }], baseline);
  expect(result.coverageGaps).toEqual(baseline.coverageGaps);
});

test("exclusive containers require captured parts and honor an explicit minimum", async () => {
  const empty = [node("row", "rows", 0, 0, 300, 28)];
  const exclusive = rowRules.find((rule) => rule.kind === "exclusive-parts")!;
  expect((await check(empty, [exclusive])).findings.some((finding) => finding.message.includes("missing peers"))).toBe(true);
  empty.push(node("spinner", "indicators", 280, 7, 14, 14, "row", "spinner"));
  expect((await check(empty, [exclusive])).passed).toBe(true);
  expect((await check(empty, [{ ...exclusive, minCount: 2 }])).passed).toBe(false);
});
