import { parseClientEnvelope, type ClientEnvelope } from "./protocol";

export const MAX_CREATE_BODY_BYTES = 8 * 1_024;
export const MAX_CONTROL_FRAME_BYTES = 64 * 1_024;
export const MAX_BULK_FRAME_BYTES = 2 * 1_024 * 1_024;
export const MAX_CHAT_CHARACTERS = 500;
export const MAX_WORKSPACE_TITLE_CHARACTERS = 160;
export const MAX_TEXT_OPERATION_ATOMS = 256;
export const MAX_TEXT_IDENTIFIER_CLOCK = 999_999_999;

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
  return type === "workspace.snapshot" || type === "terminal.grid" ||
    type === "panel.frame" || type === "textbox.document";
}
