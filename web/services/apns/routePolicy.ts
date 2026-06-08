export const MAX_DEVICE_TOKENS_PER_USER = 10;

export const MAX_PUSH_TITLE_CHARS = 120;
export const MAX_PUSH_SUBTITLE_CHARS = 120;
export const MAX_PUSH_BODY_CHARS = 500;
export const MAX_PUSH_ID_CHARS = 200;
export const MAX_PUSH_REQUEST_BYTES = 8 * 1024;

/// Defensive upper bound on a user's muted-workspace set, mirroring the iOS
/// `PushRegistrationService.maxMutedWorkspaces`. Bounds the mute-sync body and
/// the per-user rows stored server-side.
export const MAX_MUTED_WORKSPACES_PER_USER = 500;

/// Byte cap for the mute-sync `PUT` body. Unlike a single push, a full muted
/// set can legitimately carry up to `MAX_MUTED_WORKSPACES_PER_USER` ids of up to
/// `MAX_PUSH_ID_CHARS` chars each, so the 8 KiB push limit would 413 a valid
/// max-size set. Size it to the worst-case set (ids at the char bound) plus JSON
/// structural overhead (quotes, commas, the `{"workspaceIds":[...]}` envelope),
/// so the parser's per-id and per-set bounds — not the byte gate — are what
/// reject oversized input.
export const MAX_MUTE_REQUEST_BYTES =
  MAX_MUTED_WORKSPACES_PER_USER * (MAX_PUSH_ID_CHARS + 4) + 64;

export type ApnsBundlePolicy = {
  readonly bundleId: string;
  readonly environment: "sandbox" | "production";
};

export type PushPayload = {
  readonly title: string;
  readonly subtitle: string | null;
  readonly body: string;
  readonly workspaceId: string | null;
  readonly surfaceId: string | null;
  readonly hideContent: boolean;
};

export type PushPayloadResult =
  | { readonly ok: true; readonly value: PushPayload }
  | { readonly ok: false; readonly error: string };

export type JsonObjectResult =
  | { readonly ok: true; readonly value: Record<string, unknown> }
  | { readonly ok: false; readonly error: "invalid_json" | "request_too_large" };

export type MuteWorkspacesResult =
  | { readonly ok: true; readonly value: readonly string[] }
  | { readonly ok: false; readonly error: string };

const DEV_TAGGED_BUNDLE_ID = /^dev\.cmux\.ios\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const PROD_BUNDLE_IDS = new Set(["com.cmuxterm.app", "dev.cmux.app.beta"]);

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function boundedString(value: unknown, maxChars: number): string | null {
  const text = stringValue(value);
  if (text.length > maxChars) return null;
  return text;
}

export function normalizeApnsBundle(bundleId: string): ApnsBundlePolicy | null {
  const normalized = bundleId.trim();
  if (PROD_BUNDLE_IDS.has(normalized)) {
    return { bundleId: normalized, environment: "production" };
  }
  if (DEV_TAGGED_BUNDLE_ID.test(normalized)) {
    return { bundleId: normalized, environment: "sandbox" };
  }
  return null;
}

export function parsePushPayload(body: Record<string, unknown>): PushPayloadResult {
  const title = boundedString(body.title, MAX_PUSH_TITLE_CHARS);
  const subtitle = body.subtitle == null ? "" : boundedString(body.subtitle, MAX_PUSH_SUBTITLE_CHARS);
  const text = boundedString(body.body, MAX_PUSH_BODY_CHARS);
  const workspaceId = body.workspaceId == null ? "" : boundedString(body.workspaceId, MAX_PUSH_ID_CHARS);
  const surfaceId = body.surfaceId == null ? "" : boundedString(body.surfaceId, MAX_PUSH_ID_CHARS);

  if (title == null) return { ok: false, error: "title_too_long" };
  if (subtitle == null) return { ok: false, error: "subtitle_too_long" };
  if (text == null) return { ok: false, error: "body_too_long" };
  if (workspaceId == null) return { ok: false, error: "workspace_id_too_long" };
  if (surfaceId == null) return { ok: false, error: "surface_id_too_long" };
  if (!title && !text) return { ok: false, error: "empty_notification" };

  return {
    ok: true,
    value: {
      title,
      subtitle: subtitle || null,
      body: text,
      workspaceId: workspaceId || null,
      surfaceId: surfaceId || null,
      hideContent: body.hideContent === true,
    },
  };
}

/// Parse and normalize the `workspaceIds` array of a mute-sync `PUT`. Returns a
/// deduplicated, bounded set of non-empty ids. The full set is an idempotent
/// replacement of the user's muted workspaces.
export function parseMuteWorkspacesPayload(body: Record<string, unknown>): MuteWorkspacesResult {
  const raw = body.workspaceIds;
  if (raw === undefined || raw === null) {
    // Treat a missing array as "clear all mutes" so an unmute-to-empty syncs.
    return { ok: true, value: [] };
  }
  if (!Array.isArray(raw)) return { ok: false, error: "workspace_ids_not_array" };

  const seen = new Set<string>();
  for (const entry of raw) {
    const id = boundedString(entry, MAX_PUSH_ID_CHARS);
    if (id == null) return { ok: false, error: "workspace_id_too_long" };
    if (!id) continue;
    seen.add(id);
    if (seen.size > MAX_MUTED_WORKSPACES_PER_USER) {
      return { ok: false, error: "too_many_muted_workspaces" };
    }
  }
  return { ok: true, value: [...seen] };
}

/// Pure delivery decision: `true` when a push for `workspaceId` should be sent,
/// given the user's muted-workspace set. A `null`/empty workspace id is never
/// muted (it cannot match a stored id), so it always delivers. Mirrors the iOS
/// `PushMutePolicy.shouldDeliver`.
export function shouldDeliverToWorkspace(
  workspaceId: string | null,
  mutedWorkspaceIds: ReadonlySet<string>,
): boolean {
  if (!workspaceId) return true;
  return !mutedWorkspaceIds.has(workspaceId);
}

export async function readBoundedJsonObject(
  request: Request,
  maxBytes: number,
): Promise<JsonObjectResult> {
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const parsedLength = Number(contentLength);
    if (Number.isFinite(parsedLength) && parsedLength > maxBytes) {
      return { ok: false, error: "request_too_large" };
    }
  }

  const textResult = await readBoundedText(request, maxBytes);
  if (!textResult.ok) return textResult;
  const text = textResult.value;
  if (!text) return { ok: true, value: {} };

  try {
    const raw = JSON.parse(text) as unknown;
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      return { ok: false, error: "invalid_json" };
    }
    return { ok: true, value: raw as Record<string, unknown> };
  } catch {
    return { ok: false, error: "invalid_json" };
  }
}

async function readBoundedText(
  request: Request,
  maxBytes: number,
): Promise<{ readonly ok: true; readonly value: string } | { readonly ok: false; readonly error: "request_too_large" }> {
  if (!request.body) {
    return { ok: true, value: "" };
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > maxBytes) {
      await reader.cancel();
      return { ok: false, error: "request_too_large" };
    }
    chunks.push(value);
  }

  const body = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, value: new TextDecoder().decode(body) };
}
