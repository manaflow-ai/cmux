import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { PNG } from "pngjs";
import { lintGeometry, type GeometryRule } from "./geometry";
import { parseSidebarStates, sidebarArtifact, sidebarConfig, type SidebarContract, type SidebarState } from "./geometry-sidebar";
import { sidebarAudit } from "./geometry-sidebar-cli";

const fixture = JSON.parse(readFileSync(join(import.meta.dir, "fixtures/sidebar-capture.json"), "utf8"));
const contract: SidebarContract = JSON.parse(readFileSync(join(import.meta.dir, "geometry-sidebar-contract.json"), "utf8"));
const fresh = (): SidebarState[] => structuredClone(fixture.states);
const revision = { sha: fixture.provenance.sourceSha, source: "verified native capture fixture" };
async function check(states: SidebarState[]) {
  parseSidebarStates(states, contract);
  return lintGeometry(states.map((state) => ({ file: "fixture", artifact: sidebarArtifact(state, revision, fixture.provenance.screenshots[state.image], contract) })), sidebarConfig(states, revision, contract));
}

test("all eight measured native states pass, preserving center-only view provenance", async () => {
  const states = fresh(); expect((await check(states)).passed).toBe(true);
  const artifact = sidebarArtifact(states[0]!, revision, fixture.provenance.screenshots[states[0]!.image], contract);
  const tab = artifact.elements.find((item) => item.id === "cmux.sidebar.tab.tc-selected.tc-tab-1:center:0")!;
  expect(tab.rect).toEqual({ x: 279, y: 182, width: 0, height: 0 });
  expect(tab.role).toBe("measured-center");
  expect(artifact.elements.every((item) => item.source === "view-frame")).toBe(true);
  expect(artifact.capture.theme).toBe("unspecified");
});

test("recorded before differences fail for nested unread dots and loading-header status", async () => {
  // Owner-attested identical mapping is used only for this recorded before replay.
  const states = fresh();
  for (const delta of fixture.beforeMarkDifferences) states.find((state) => state.density === delta.density && state.state === delta.state)!.rows.find((row) => row.key === delta.row)!.marks = delta.marks;
  const report = await check(states);
  expect(report.passed).toBe(false);
  expect(new Set(report.findings.filter((finding) => finding.deltaPx !== undefined).map((finding) => finding.deltaPx))).toEqual(new Set([2, 38, 40]));
  expect(report.findings.filter((finding) => finding.rule.endsWith("-hover"))).toHaveLength(2);
});

test("a new deeper row is checked and every activity mark conflicts with hover controls", async () => {
  const states = fresh(); const row = structuredClone(states[0]!.rows.find((row) => row.key === "tab:tc-nested/tc-nested-tab-1")!);
  row.key = "tab:tc-nested/new"; row.identifier = "cmux.sidebar.tab.tc-nested.new"; row.marks[0]!.centerX += 0.51; states[0]!.rows.push(row);
  expect((await check(states)).passed).toBe(false);
  for (const what of ["dot", "status", "unreadDot"] as const) {
    const copy = fresh(); const header = copy.find((state) => state.density === "compact" && state.state === "hover-loading-header")!.rows.find((row) => row.hovered)!;
    header.marks.push({ what, centerX: 279, dyFromRowCenter: 0 });
    expect((await check(copy)).findings.some((finding) => finding.rule.endsWith("-hover"))).toBe(true);
  }
  const shifted = fresh(); shifted[0]!.rows[0]!.marks[0]!.dyFromRowCenter = 0.51;
  expect((await check(shifted)).findings.some((finding) => finding.rule.endsWith("-mark-center"))).toBe(true);
});

test("every captured control shares its row center, including non-end-slot controls", async () => {
  for (const what of ["close", "more", "disclosure"] as const) {
    const states = fresh();
    const state = states.find((state) => state.rows.some((row) => row.controls.some((control) => control.what === what)))!;
    const row = state.rows.find((row) => row.controls.some((control) => control.what === what))!;
    row.controls.find((control) => control.what === what)!.listFrame[1] += 20;
    const report = await check(states);
    expect(report.findings.some((finding) => finding.rule.endsWith("-control-center") && finding.deltaPx === 20)).toBe(true);
  }
});

test("missing states, rows, mapping, hover controls and misleading AX cannot pass", async () => {
  const mutations = [
    (states: SidebarState[]) => { states.pop(); },
    (states: SidebarState[]) => { states[0]!.rows.pop(); },
    (states: SidebarState[]) => { delete (states[0] as Partial<SidebarState>).listInImage; },
    (states: SidebarState[]) => { states[0]!.imagePixels[0] = 600; },
    (states: SidebarState[]) => { states[1]!.rows.find((row) => row.hovered)!.controls = []; },
  ];
  for (const mutate of mutations) { const states = fresh(); mutate(states); expect(() => parseSidebarStates(states, contract)).toThrow(); }
  const states = fresh(); const artifact = sidebarArtifact(states[0]!, revision, fixture.provenance.screenshots[states[0]!.image], contract);
  const config = sidebarConfig(states, revision, contract); config.required = config.required.slice(0, 1); config.rules = [{ ...config.rules[0]!, source: "ax-frame" } as GeometryRule];
  expect((await lintGeometry([{ file: "fixture", artifact }], config)).passed).toBe(false);
});

test("CLI validates PNGs and geometry hash and emits failing conversion evidence", async () => {
  const dir = await mkdtemp(join(process.cwd(), "sidebar-cli-"));
  try {
    const states = fresh(); const json = JSON.stringify(states); const hash = createHash("sha256").update(json).digest("hex");
    await writeFile(join(dir, "geometry.json"), json);
    // Synthetic PNGs test transport validation; recorded screenshots remain in the capture artifact.
    const png = PNG.sync.write(new PNG({ width: 300, height: 900 }));
    for (const state of states) await writeFile(join(dir, state.image), png);
    const args = ["--artifact-dir", dir, "--expected-sha", revision.sha, "--geometry-sha256", hash];
    expect(await sidebarAudit([...args, "--output-dir", join(dir, "valid")])).toBe(0);
    await writeFile(join(dir, states[0]!.image), "corrupt PNG");
    expect(await sidebarAudit([...args, "--output-dir", join(dir, "corrupt")])).toBe(1);
    expect(JSON.parse(await readFile(join(dir, "corrupt/conversion-error.json"), "utf8")).passed).toBe(false);
    expect(await sidebarAudit([...args.slice(0, -1), "0".repeat(64), "--output-dir", join(dir, "hash")])).toBe(1);
  } finally { await rm(dir, { recursive: true, force: true }); }
});


test("native tolerance and reported deltas stay in points at 1x and 2x", async () => {
  // A synthetic scale transform of the recorded point frames, not a second capture.
  for (const scale of [1, 2]) for (const delta of [0.5, 0.51]) {
    const states = fresh();
    for (const state of states) {
      state.backingScale = scale;
      state.imagePixels = [state.imagePoints[0] * scale, state.imagePoints[1] * scale];
    }
    states[0]!.rows[0]!.marks[0]!.centerX += delta;
    const config = sidebarConfig(states, revision, contract);
    expect(config.rules.every((rule) => rule.tolerancePx === 0.5)).toBe(true);
    const artifacts = states.map((state) => ({ file: "synthetic-scale-replay", artifact: sidebarArtifact(state,
      revision,
      { sha256: "0".repeat(64), width: state.imagePixels[0], height: state.imagePixels[1] }, contract) }));
    const rawPoint = artifacts[0]!.artifact.elements.find((element) => element.group === "trailing")!.rect.x;
    const report = await lintGeometry(artifacts, config);
    expect(report.passed).toBe(delta === 0.5);
    if (delta > 0.5) expect(report.findings.find((finding) => finding.rule.endsWith("-column"))!.deltaPx).toBeCloseTo(delta, 8);
    expect(artifacts[0]!.artifact.elements.find((element) => element.group === "trailing")!.rect.x).toBe(rawPoint);
  }
});
