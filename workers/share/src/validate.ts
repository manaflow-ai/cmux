import { parseClientEnvelope, type ClientEnvelope } from "./protocol";

export const MAX_CREATE_BODY_BYTES = 8 * 1_024;
export const MAX_CONTROL_FRAME_BYTES = 64 * 1_024;
export const MAX_BULK_FRAME_BYTES = 2 * 1_024 * 1_024;
export const MAX_CHAT_CHARACTERS = 500;
export const MAX_WORKSPACE_TITLE_CHARACTERS = 160;
export const MAX_TEXT_OPERATION_ATOMS = 256;
export const MAX_TEXT_IDENTIFIER_CLOCK = 999_999_999;
export const MAX_TERMINAL_DIMENSION = 1_000;
export const MAX_TERMINAL_CELLS = 200_000;
export const MAX_TERMINAL_VT_BYTES = 1_500_000;
export const MAX_TERMINAL_INPUT_BYTES = 4_096;
const MAX_TERMINAL_VT_BASE64_CHARACTERS = Math.ceil(MAX_TERMINAL_VT_BYTES / 3) * 4;
const MAX_WORKSPACE_PANES = 64;
const MAX_PANE_SURFACES = 128;
const MAX_WORKSPACE_SURFACES = 4_096;

export async function readBoundedJson(
  request: Request,
  maxBytes = MAX_CREATE_BODY_BYTES,
): Promise<{ ok: true; value: unknown } | { ok: false; status: 400 | 413 }> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) return { ok: false, status: 413 };
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > maxBytes) return { ok: false, status: 413 };
  try {
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, status: 400 };
  }
}

export function parseCreateRequest(value: unknown): { workspaceId: string; workspaceTitle: string } | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  const workspaceId = normalizedString(body.workspaceId, 128);
  const workspaceTitle = normalizedString(body.workspaceTitle, MAX_WORKSPACE_TITLE_CHARACTERS);
  return workspaceId && workspaceTitle ? { workspaceId, workspaceTitle } : null;
}

export function parseMessage(message: string | ArrayBuffer): ClientEnvelope | null {
  const byteLength = typeof message === "string" ? new TextEncoder().encode(message).byteLength : message.byteLength;
  if (byteLength > MAX_BULK_FRAME_BYTES) return null;
  let decoded: unknown;
  try {
    decoded = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
  } catch {
    return null;
  }
  const envelope = parseClientEnvelope(decoded);
  if (!envelope) return null;
  if (!isBulkType(envelope.type) && byteLength > MAX_CONTROL_FRAME_BYTES) return null;
  return envelope;
}

export function normalizedChat(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/gu, "").trim();
  return text && [...text].length <= MAX_CHAT_CHARACTERS ? text : null;
}

export function validPointerPayload(payload: Record<string, unknown>): boolean {
  return (
    exactKeys(payload, ["x", "y", "layoutRevision"], ["targetId"]) &&
    finiteRatio(payload.x) &&
    finiteRatio(payload.y) &&
    typeof payload.layoutRevision === "number" &&
    Number.isSafeInteger(payload.layoutRevision) &&
    payload.layoutRevision >= 0 &&
    optionalShortString(payload.targetId, 128)
  );
}

export function validTextSelectionPayload(payload: Record<string, unknown>): boolean {
  return exactKeys(payload, ["docId", "anchorUTF16", "headUTF16"]) &&
    normalizedString(payload.docId, 128) !== null &&
    boundedInteger(payload.anchorUTF16, 10_000_000) &&
    boundedInteger(payload.headUTF16, 10_000_000);
}

export function validTextOperationPayload(
  payload: Record<string, unknown>,
  expectedClientId?: string,
): boolean {
  if (!exactKeys(payload, ["operation"])) return false;
  if (!payload.operation || typeof payload.operation !== "object" || Array.isArray(payload.operation)) return false;
  const operation = payload.operation as Record<string, unknown>;
  if (
    !identifier(operation.opId) ||
    (expectedClientId !== undefined && identifierClientId(operation.opId) !== expectedClientId) ||
    normalizedString(operation.docId, 128) === null ||
    (operation.kind !== "insert" && operation.kind !== "delete")
  ) return false;
  if (operation.kind === "insert") {
    if (!exactKeys(operation, ["opId", "docId", "kind", "atoms"]) ||
        !Array.isArray(operation.atoms) ||
        operation.atoms.length < 1 ||
        operation.atoms.length > MAX_TEXT_OPERATION_ATOMS) return false;
    return operation.atoms.every((value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return false;
      const atom = value as Record<string, unknown>;
      return exactKeys(atom, ["id", "afterId", "value", "deleted"]) &&
        identifier(atom.id) &&
        (expectedClientId === undefined || identifierClientId(atom.id) === expectedClientId) &&
        (atom.afterId === null || identifier(atom.afterId)) &&
        typeof atom.value === "string" &&
        graphemeCount(atom.value) === 1 &&
        new TextEncoder().encode(atom.value).byteLength <= 64 &&
        atom.deleted === false;
    });
  }
  return exactKeys(operation, ["opId", "docId", "kind", "atomIds"]) &&
    Array.isArray(operation.atomIds) &&
    operation.atomIds.length >= 1 &&
    operation.atomIds.length <= MAX_TEXT_OPERATION_ATOMS &&
    operation.atomIds.every(identifier);
}

export function validResyncPayload(payload: Record<string, unknown>): boolean {
  return exactKeys(payload, [], ["reason"]) && optionalShortString(payload.reason, 64);
}

export function validAccessDecisionPayload(payload: Record<string, unknown>): boolean {
  return exactKeys(payload, ["userId", "decision"]) &&
    normalizedString(payload.userId, 256) !== null &&
    (payload.decision === "allow" || payload.decision === "deny");
}

export function validTerminalVTPayload(payload: Record<string, unknown>): boolean {
  return exactKeys(payload, [
    "surfaceId",
    "generation",
    "stateSeq",
    "columns",
    "rows",
    "kind",
    "dataB64",
  ]) &&
    typeof payload.surfaceId === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(payload.surfaceId) &&
    boundedPositiveInteger(payload.generation, Number.MAX_SAFE_INTEGER) &&
    boundedPositiveInteger(payload.stateSeq, Number.MAX_SAFE_INTEGER) &&
    boundedPositiveInteger(payload.columns, MAX_TERMINAL_DIMENSION) &&
    boundedPositiveInteger(payload.rows, MAX_TERMINAL_DIMENSION) &&
    (payload.columns as number) * (payload.rows as number) <= MAX_TERMINAL_CELLS &&
    (payload.kind === "snapshot" || payload.kind === "patch") &&
    validBoundedBase64(payload.dataB64);
}

export function validTerminalInputPayload(payload: Record<string, unknown>): boolean {
  if (!exactKeys(payload, ["surfaceId", "layoutRevision", "kind", "data"]) ||
      !validSurfaceId(payload.surfaceId) ||
      !boundedInteger(payload.layoutRevision, Number.MAX_SAFE_INTEGER) ||
      typeof payload.data !== "string") return false;
  if (payload.kind === "key") return validTerminalInputKey(payload.data);
  return payload.kind === "text" && validTerminalInputText(payload.data);
}

export function selectedTerminalTargetsFromWorkspacePayload(
  payload: Record<string, unknown>,
): { readonly layoutRevision: number; readonly surfaceIds: readonly string[] } | null {
  const sceneValue = Object.hasOwn(payload, "scene") ? payload.scene : payload;
  if (!sceneValue || typeof sceneValue !== "object" || Array.isArray(sceneValue)) return null;
  const scene = sceneValue as Record<string, unknown>;
  if (!boundedInteger(scene.layoutRevision, Number.MAX_SAFE_INTEGER) ||
      !Array.isArray(scene.panes) || scene.panes.length > MAX_WORKSPACE_PANES) return null;

  const paneIds = new Set<string>();
  const surfaceIds = new Set<string>();
  const selectedTerminalIds: string[] = [];
  let surfaceCount = 0;
  for (const paneValue of scene.panes) {
    if (!paneValue || typeof paneValue !== "object" || Array.isArray(paneValue)) return null;
    const pane = paneValue as Record<string, unknown>;
    const paneId = normalizedString(pane.id, 128);
    const selectedSurfaceId = typeof pane.selectedSurfaceId === "string" ? pane.selectedSurfaceId : null;
    if (!paneId || paneIds.has(paneId) || !selectedSurfaceId || !Array.isArray(pane.surfaces) ||
        pane.surfaces.length < 1 || pane.surfaces.length > MAX_PANE_SURFACES) return null;
    paneIds.add(paneId);
    surfaceCount += pane.surfaces.length;
    if (surfaceCount > MAX_WORKSPACE_SURFACES) return null;

    let selectedKind: unknown;
    for (const surfaceValue of pane.surfaces) {
      if (!surfaceValue || typeof surfaceValue !== "object" || Array.isArray(surfaceValue)) return null;
      const surface = surfaceValue as Record<string, unknown>;
      if (!validSurfaceId(surface.id) || surfaceIds.has(surface.id as string) ||
          !["terminal", "textbox", "browser", "unsupported"].includes(String(surface.kind))) return null;
      surfaceIds.add(surface.id as string);
      if (surface.id === selectedSurfaceId) selectedKind = surface.kind;
    }
    if (selectedKind === undefined) return null;
    if (selectedKind === "terminal" || selectedKind === "textbox") selectedTerminalIds.push(selectedSurfaceId);
  }
  return {
    layoutRevision: scene.layoutRevision as number,
    surfaceIds: selectedTerminalIds,
  };
}

function normalizedString(value: unknown, maxCharacters: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result && [...result].length <= maxCharacters ? result : null;
}

function optionalShortString(value: unknown, maxCharacters: number): boolean {
  return value === undefined || value === null || normalizedString(value, maxCharacters) !== null;
}

function finiteRatio(value: unknown): boolean {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

function boundedInteger(value: unknown, maximum: number): boolean {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= maximum;
}

function boundedPositiveInteger(value: unknown, maximum: number): boolean {
  return typeof value === "number" && boundedInteger(value, maximum) && value > 0;
}

function validBoundedBase64(value: unknown): boolean {
  if (typeof value !== "string" || value.length < 4 ||
      value.length > MAX_TERMINAL_VT_BASE64_CHARACTERS || value.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]*={0,2}$/u.test(value)) return false;
  const firstPadding = value.indexOf("=");
  if (firstPadding >= 0 && firstPadding < value.length - 2) return false;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  const decodedBytes = value.length / 4 * 3 - padding;
  return decodedBytes > 0 && decodedBytes <= MAX_TERMINAL_VT_BYTES;
}

function validTerminalInputText(value: string): boolean {
  if (!value || new TextEncoder().encode(value).byteLength > MAX_TERMINAL_INPUT_BYTES) return false;
  return [...value].every((character) => {
    const code = character.codePointAt(0) ?? 0;
    return code > 0x1F && !(code >= 0x7F && code <= 0x9F);
  });
}

function validTerminalInputKey(value: string): boolean {
  return [
    "enter", "backspace", "tab", "shift-tab", "escape", "up", "down", "left", "right",
    "home", "end", "delete",
  ].includes(value) || /^ctrl-[a-z\\]$/u.test(value);
}

function validSurfaceId(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(value);
}

function identifier(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = /^(\d{12}):[A-Za-z0-9._-]{1,128}$/u.exec(value);
  if (!match?.[1]) return false;
  const clock = Number(match[1]);
  return Number.isSafeInteger(clock) && clock <= MAX_TEXT_IDENTIFIER_CLOCK;
}

function identifierClientId(value: string): string | null {
  const separator = value.indexOf(":");
  return separator >= 0 ? value.slice(separator + 1) : null;
}

function graphemeCount(value: string): number {
  return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(value)].length;
}

function exactKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): boolean {
  const keys = Object.keys(value);
  const allowed = new Set([...required, ...optional]);
  return required.every((key) => Object.hasOwn(value, key)) && keys.every((key) => allowed.has(key));
}

function isBulkType(type: string): boolean {
  return type === "workspace.snapshot" || type === "terminal.vt" ||
    type === "panel.frame" || type === "textbox.document";
}
