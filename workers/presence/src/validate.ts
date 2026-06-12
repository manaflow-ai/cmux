// Heartbeat request validation. Bounds and identifier rules copied from the
// device-registry route (`web/app/api/devices/route.ts`) so the same client
// payload conventions hold across the durable registry and this ephemeral
// presence layer.

import type { HeartbeatInput, PresenceRoute } from "./core";

export const MAX_REQUEST_BYTES = 16 * 1024;
export const MAX_TAG_LENGTH = 64;
export const MAX_DISPLAY_NAME_LENGTH = 128;
export const MAX_CAPABILITIES = 32;
export const MAX_CAPABILITY_LENGTH = 64;
/** Mirrors the registry route's `MAX_ROUTES` (`web/app/api/devices/route.ts`):
 * hosts publish the same bounded set to both. */
export const MAX_ROUTES = 16;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const ALLOWED_PLATFORMS: ReadonlySet<string> = new Set([
  "mac",
  "ios",
  "linux",
  "windows",
]);

export type HeartbeatParse =
  | { ok: true; beat: HeartbeatInput }
  | { ok: false; error: string };

function trimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

/** Parse and bound a heartbeat body that has already been JSON-decoded. Pure
 * for tests. */
export function parseHeartbeat(body: Record<string, unknown>): HeartbeatParse {
  const deviceId = trimmedString(body.deviceId).toLowerCase();
  if (!UUID_RE.test(deviceId)) return { ok: false, error: "invalid_device_id" };

  const platform = trimmedString(body.platform).toLowerCase();
  if (!ALLOWED_PLATFORMS.has(platform)) return { ok: false, error: "invalid_platform" };

  const tag = trimmedString(body.tag) || "default";
  if (tag.length > MAX_TAG_LENGTH) return { ok: false, error: "invalid_tag" };

  const displayName = trimmedString(body.displayName);
  if (displayName.length > MAX_DISPLAY_NAME_LENGTH) {
    return { ok: false, error: "invalid_display_name" };
  }

  let capabilities: string[] | undefined;
  if (body.capabilities !== undefined) {
    if (!Array.isArray(body.capabilities)) return { ok: false, error: "invalid_capabilities" };
    capabilities = [];
    for (const entry of body.capabilities) {
      const value = trimmedString(entry);
      if (!value || value.length > MAX_CAPABILITY_LENGTH) {
        return { ok: false, error: "invalid_capabilities" };
      }
      capabilities.push(value);
      if (capabilities.length > MAX_CAPABILITIES) {
        return { ok: false, error: "invalid_capabilities" };
      }
    }
  }

  const stopping = body.stopping === true;

  // Routes are tri-state on the heartbeat wire (see HeartbeatInput): absent
  // means "unchanged", `[]` means "no routes". A present-but-non-array value is
  // rejected rather than coerced like the registry route does, because under
  // presence semantics a silent coercion would either wipe pushed routes
  // (treat-as-empty) or mask a client bug (treat-as-absent). Entry filtering
  // mirrors the registry: keep only plain objects, bounded by MAX_ROUTES;
  // semantic `CmxAttachRoute` validation stays client-owned so new route kinds
  // flow through without a worker ship.
  let routes: PresenceRoute[] | undefined;
  if (body.routes !== undefined) {
    if (!Array.isArray(body.routes)) return { ok: false, error: "invalid_routes" };
    routes = body.routes
      .filter(
        (entry): entry is PresenceRoute =>
          entry !== null && typeof entry === "object" && !Array.isArray(entry),
      )
      .slice(0, MAX_ROUTES);
  }

  return {
    ok: true,
    beat: {
      deviceId,
      tag,
      platform,
      displayName: displayName || undefined,
      capabilities,
      stopping: stopping || undefined,
      routes,
    },
  };
}

/** Bounded JSON body reader. Unlike the registry route's post-hoc length
 * check, this reads the stream incrementally and aborts the moment it crosses
 * the cap, so a chunked or lying-Content-Length body can never make the
 * worker buffer more than MAX_REQUEST_BYTES. */
export async function readBoundedJson(
  request: Request,
): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; status: number }> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader && Number(lengthHeader) > MAX_REQUEST_BYTES) {
    return { ok: false, status: 413 };
  }
  if (!request.body) return { ok: false, status: 400 };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > MAX_REQUEST_BYTES) {
        await reader.cancel();
        return { ok: false, status: 413 };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, status: 400 };
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return { ok: false, status: 400 };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, status: 400 };
  }
  return { ok: true, value: parsed as Record<string, unknown> };
}
