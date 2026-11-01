import type { GeometryArtifact, GeometryConfig, GeometryElement, GeometryRule, Rect } from "./geometry";

export type Frame = [number, number, number, number];
export type SidebarRow = {
  key: string; identifier: string; kind: "workspace" | "groupHeader" | "innerTab";
  parent?: string; depth: number; hovered: boolean; listFrame: Frame;
  marks: Array<{ what: "dot" | "status" | "unreadDot" | "chevron"; centerX: number; dyFromRowCenter: number }>;
  controls: Array<{ what: "close" | "more" | "pin" | "disclosure" | "add"; listFrame: Frame }>;
};
export type SidebarState = {
  density: string; state: string; width: number; columnCenterX: number; image: string;
  backingScale: number; imagePoints: [number, number]; imagePixels: [number, number];
  listInImage: Frame; listIsFlipped: true; rows: SidebarRow[];
};
export type SidebarContract = {
  densities: string[];
  states: Array<{ name: string; hoveredRow?: string; requiredControls?: string[]; requiredMarks?: string[] }>;
  requiredRows: Array<{ key: string; kind: SidebarRow["kind"]; parent?: string; depth: number }>;
  tolerancePoints: number;
  endSpotControls: Array<SidebarRow["controls"][number]["what"]>;
};
export type ScreenshotInfo = { sha256: string; width: number; height: number };
const finite = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
const tuple = (value: unknown, size: number) => Array.isArray(value) && value.length === size && value.every(finite);
const frame = (value: unknown): value is Frame => tuple(value, 4) && (value as Frame)[2] > 0 && (value as Frame)[3] > 0;
const fail = (message: string): never => { throw new Error(`sidebar geometry: ${message}`); };
const caseId = (state: SidebarState) => `sidebar-${state.density}-${state.state}`;

/** Preserve the export's view coordinates. These are neither AX frames nor icon ink bounds. */
export function parseSidebarStates(value: unknown, contract: SidebarContract): SidebarState[] {
  if (!Array.isArray(contract.densities) || !contract.densities.length || new Set(contract.densities).size !== contract.densities.length || contract.densities.some((value) => typeof value !== "string" || !value) || !Array.isArray(contract.states) || !contract.states.length || new Set(contract.states.map((state) => state.name)).size !== contract.states.length || !Array.isArray(contract.requiredRows) || !contract.requiredRows.length || !finite(contract.tolerancePoints) || contract.tolerancePoints < 0 || !Array.isArray(contract.endSpotControls)) fail("invalid declarative fixture contract");
  if (!Array.isArray(value) || !value.length) return fail("state evidence is missing");
  const seen = new Set<string>();
  for (const raw of value) {
    const state = raw as SidebarState;
    if (!state || !contract.densities.includes(state.density) || !contract.states.some((item) => item.name === state.state)) fail("unknown density/state");
    const key = caseId(state);
    if (seen.has(key)) fail(`duplicate state ${key}`);
    seen.add(key);
    if (!finite(state.backingScale) || state.backingScale <= 0 || !tuple(state.imagePoints, 2) || state.imagePoints.some((n) => n <= 0) || !tuple(state.imagePixels, 2) || state.imagePixels.some((n) => !Number.isInteger(n) || n <= 0)) fail(`${key}: missing screenshot mapping`);
    if (!frame(state.listInImage) || state.listIsFlipped !== true || !finite(state.width) || state.width !== state.listInImage[2] || !finite(state.columnCenterX)) fail(`${key}: unsupported list mapping`);
    if (state.imagePixels.some((n, index) => n !== Math.round(state.imagePoints[index]! * state.backingScale))) fail(`${key}: inconsistent screenshot scale`);
    if (state.listInImage[0] < 0 || state.listInImage[1] < 0 || state.listInImage[0] + state.listInImage[2] > state.imagePoints[0] || state.listInImage[1] + state.listInImage[3] > state.imagePoints[1] || state.columnCenterX < 0 || state.columnCenterX > state.width) fail(`${key}: list/column outside screenshot`);
    if (typeof state.image !== "string" || !/^[a-z0-9-]+\.png$/.test(state.image)) fail(`${key}: image must be a local PNG filename`);
    if (!Array.isArray(state.rows) || !state.rows.length) fail(`${key}: missing rows`);
    const rows = new Map<string, SidebarRow>(); const identifiers = new Set<string>();
    const hovered = contract.states.find((item) => item.name === state.state)!.hoveredRow;
    for (const row of state.rows) {
      if (!row || typeof row.key !== "string" || !row.key || rows.has(row.key) || typeof row.identifier !== "string" || !row.identifier.startsWith("cmux.sidebar.") || identifiers.has(row.identifier)) fail(`${key}: invalid/duplicate row identity`);
      rows.set(row.key, row); identifiers.add(row.identifier);
      if (!["workspace", "groupHeader", "innerTab"].includes(row.kind) || !Number.isInteger(row.depth) || row.depth < 0 || typeof row.hovered !== "boolean" || !frame(row.listFrame)) fail(`${key}: malformed row ${row.key}`);
      if (row.hovered !== (row.key === hovered)) fail(`${key}: hover state disagrees with declared fixture`);
      if (!Array.isArray(row.marks) || !Array.isArray(row.controls)) fail(`${key}: missing drawn mark/control inventory`);
      for (const mark of row.marks) if (!["dot", "status", "unreadDot", "chevron"].includes(mark.what) || !finite(mark.centerX) || !finite(mark.dyFromRowCenter)) fail(`${key}: invalid drawn mark`);
      const controls = new Set<string>();
      for (const control of row.controls) {
        if (!["close", "more", "pin", "disclosure", "add"].includes(control.what) || controls.has(control.what) || !frame(control.listFrame)) fail(`${key}: invalid/duplicate drawn control`);
        controls.add(control.what);
      }
    }
    for (const row of state.rows) if (row.parent && (!rows.has(row.parent) || rows.get(row.parent)!.depth + 1 !== row.depth)) fail(`${key}: missing/inconsistent parent for ${row.key}`);
    for (const required of contract.requiredRows) {
      const row = rows.get(required.key);
      if (!row || row.kind !== required.kind || row.parent !== required.parent || row.depth !== required.depth) fail(`${key}: missing/changed required row ${required.key}`);
      if (!row.hovered && !row.marks.length) fail(`${key}: activity fixture row lost its mark ${row.key}`);
    }
    if (hovered) {
      const row = rows.get(hovered); const expected = contract.states.find((item) => item.name === state.state)!;
      if (!row?.controls.length || expected.requiredControls?.some((what) => !row.controls.some((control) => control.what === what)) || expected.requiredMarks?.some((what) => !row.marks.some((mark) => mark.what === what))) fail(`${key}: required hovered controls/structural marks were not captured`);
    }
  }
  for (const density of contract.densities) for (const state of contract.states) if (!seen.has(`sidebar-${density}-${state.name}`)) fail(`missing required state ${density}/${state.name}`);
  return value as SidebarState[];
}

export function sidebarArtifact(state: SidebarState, revision: GeometryArtifact["revision"], screenshot: ScreenshotInfo, contract: SidebarContract): GeometryArtifact {
  if (!/^[a-f0-9]{64}$/.test(screenshot.sha256) || screenshot.width !== state.imagePixels[0] || screenshot.height !== state.imagePixels[1]) fail(`${caseId(state)}: PNG dimensions/hash disagree with mapping`);
  const scale = state.backingScale;
  const mapped = ([x, y, width, height]: Frame): Rect => ({ x: (state.listInImage[0] + x) * scale, y: (state.listInImage[1] + y) * scale, width: width * scale, height: height * scale });
  const elements: GeometryElement[] = [];
  const add = (id: string, group: string, rect: Rect, containerId?: string, part?: string, role?: string) => {
    if (rect.x < 0 || rect.y < 0 || rect.x + rect.width > screenshot.width || rect.y + rect.height > screenshot.height) fail(`${caseId(state)}: measurement outside screenshot ${id}`);
    elements.push({ id, group, kind: "native", source: "view-frame", rect, containerId, part, role });
  };
  add("column", "column", mapped([state.columnCenterX, 0, 0, state.listInImage[3]]), undefined, undefined, "layout-guide");
  for (const row of state.rows) {
    const rowId = row.identifier;
    if (row.marks.length) add(`${rowId}:marks`, "marked-rows", mapped(row.listFrame));
    if (row.hovered) add(`${rowId}:hover`, "hovered-rows", mapped(row.listFrame));
    if (row.controls.length) add(`${rowId}:controls`, "control-rows", mapped(row.listFrame));
    row.marks.forEach((mark, index) => {
      // The exporter records centers only: zero-area points avoid inventing icon bounds.
      const rect = mapped([mark.centerX, row.listFrame[1] + row.listFrame[3] / 2 + mark.dyFromRowCenter, 0, 0]);
      add(`${rowId}:column:${index}`, "trailing", rect, "column", undefined, "measured-center");
      add(`${rowId}:center:${index}`, "mark-centers", rect, `${rowId}:marks`, undefined, "measured-center");
      if (row.hovered && mark.what !== "chevron") add(`${rowId}:activity:${index}`, "hover-parts", rect, `${rowId}:hover`, "activity", "measured-center");
    });
    row.controls.forEach((control) => {
      const rect = mapped(control.listFrame);
      if (contract.endSpotControls.includes(control.what)) {
        add(`${rowId}:end:${control.what}`, "trailing", rect, "column");
      }
      add(`${rowId}:control:${control.what}`, "control-centers", rect, `${rowId}:controls`);
      if (row.hovered) add(`${rowId}:hover:${control.what}`, "hover-parts", rect, `${rowId}:hover`, "control");
    });
  }
  return { schemaVersion: 1, revision, capture: { caseId: caseId(state), engine: "appkit", theme: "unspecified", viewport: { width: state.imagePoints[0], height: state.imagePoints[1] }, deviceScaleFactor: scale, coordinateSpace: "screenshot-pixels", screenshot: state.image, screenshotSha256: screenshot.sha256 }, elements };
}

export function sidebarConfig(states: SidebarState[], revision: GeometryArtifact["revision"], contract: SidebarContract): GeometryConfig {
  const rules: GeometryRule[] = [];
  for (const state of states) {
    const common = { tolerancePx: contract.tolerancePoints, source: "view-frame" as const, appliesTo: [caseId(state)], minCount: 1 };
    rules.push({ ...common, id: `${caseId(state)}-column`, kind: "container-center", group: "trailing", containerGroup: "column", axis: "x" }, { ...common, id: `${caseId(state)}-mark-center`, kind: "container-center", group: "mark-centers", containerGroup: "marked-rows", axis: "y" });
    if (state.rows.some((row) => row.hovered)) rules.push({ ...common, id: `${caseId(state)}-hover`, kind: "exclusive-parts", group: "hover-parts", containerGroup: "hovered-rows", parts: ["activity", "control"] });
    if (state.rows.some((row) => row.controls.length)) rules.push({ ...common, id: `${caseId(state)}-control-center`, kind: "container-center", group: "control-centers", containerGroup: "control-rows", axis: "y" });
  }
  return { schemaVersion: 1, revision, required: states.map((state) => ({ caseId: caseId(state), engine: "appkit", theme: "unspecified" })), rules, coverageGaps: ["Native evidence contains view frames and measured centers, not AX frames or visible ink bounds.", "The native fixture does not export a theme identity; light/dark coverage is unspecified."] };
}
