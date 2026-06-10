export const MAX_DEVICE_TOKENS_PER_USER = 10;

export const MAX_PUSH_TITLE_CHARS = 120;
export const MAX_PUSH_SUBTITLE_CHARS = 120;
export const MAX_PUSH_BODY_CHARS = 500;
export const MAX_PUSH_ID_CHARS = 200;
export const MAX_PUSH_REQUEST_BYTES = 8 * 1024;

/// Defensive upper bound on a user's muted-workspace set, mirroring the iOS
/// `PushRegistrationService.maxMutedWorkspaces`. Bounds the per-user rows the
/// client will defensively cache/hydrate.
export const MAX_MUTED_WORKSPACES_PER_USER = 500;

/// Byte cap for a per-workspace mute mutation `POST` body. The body is a single
/// `{ workspaceId, muted }`, so a small cap (one bounded id + the boolean + JSON
/// overhead) is plenty; the parser's id-length bound is the real gate.
export const MAX_MUTE_REQUEST_BYTES = MAX_PUSH_ID_CHARS + 128;

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

export type MuteMutation = {
  readonly workspaceId: string;
  readonly muted: boolean;
};

export type MuteMutationResult =
  | { readonly ok: true; readonly value: MuteMutation }
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

/// Parse a single per-workspace mute mutation `POST` (`{ workspaceId, muted }`).
/// One add/remove per request keeps multiple devices on the same account from
/// clobbering each other (no full-set replace from a stale local cache).
export function parseMuteMutationPayload(body: Record<string, unknown>): MuteMutationResult {
  const workspaceId = boundedString(body.workspaceId, MAX_PUSH_ID_CHARS);
  if (workspaceId == null) return { ok: false, error: "workspace_id_too_long" };
  if (!workspaceId) return { ok: false, error: "workspace_id_required" };
  if (typeof body.muted !== "boolean") return { ok: false, error: "muted_not_boolean" };
  return { ok: true, value: { workspaceId, muted: body.muted } };
}

/// Pure delivery decision: `true` when a push for `workspaceId` should be sent,
/// given the user's muted-workspace set. A `null`/empty workspace id is never
/// muted (it cannot match a stored id), so it always delivers. Mirrors the iOS
/// `pushShouldDeliver`.
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
