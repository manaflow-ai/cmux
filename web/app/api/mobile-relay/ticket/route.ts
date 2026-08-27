// Mobile relay ticket mint — the ONLY authority that turns a Stack session
// into relay access (workers/mobile-relay).
//
// POST { hostDeviceId, deviceId, role: "host" | "client" }
//   -> { ticket, relayUrl, expiresAt, protocolVersion }
//
// Auth: native Stack bearer + refresh header only (no cookie), the same seam
// as /api/devices. Ownership: the caller must have a device-registry row for
// hostDeviceId registered under their own user id (any of their teams); a
// host additionally proves it is minting for itself (deviceId ==
// hostDeviceId). The relay object id embeds the VERIFIED user id, so a ticket
// can never reach another user's relay even if these checks are bypassed;
// they exist as defense in depth and to keep unpaired devices out.
//
// Stack tokens never cross the relay socket: the ticket is the only
// credential the worker ever sees.

import { and, eq } from "drizzle-orm";
import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { devices } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { enforceNativeIngressRateLimit } from "../../../../services/nativeIngressRateLimit";
import {
  DEFAULT_RELAY_URL,
  PROTOCOL_VERSION,
  TICKET_TTL_SECONDS,
} from "../../../../services/mobileRelay/generated/protocol";
import { mintTicket } from "../../../../services/mobileRelay/generated/ticket";

const MAX_REQUEST_BYTES = 4 * 1024;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface TicketRequestBody {
  readonly hostDeviceId: string;
  readonly deviceId: string;
  readonly role: "host" | "client";
}

function parseBody(value: unknown): TicketRequestBody | null {
  if (typeof value !== "object" || value === null) return null;
  const body = value as Record<string, unknown>;
  const hostDeviceId = typeof body.hostDeviceId === "string" ? body.hostDeviceId.trim() : "";
  const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
  const role = body.role;
  if (!UUID_RE.test(hostDeviceId) || !UUID_RE.test(deviceId)) return null;
  if (role !== "host" && role !== "client") return null;
  return { hostDeviceId: hostDeviceId.toLowerCase(), deviceId: deviceId.toLowerCase(), role };
}

export async function POST(request: Request): Promise<Response> {
  const limited = await enforceNativeIngressRateLimit({
    request,
    route: "mobileRelay.ticket",
    ruleId: env.CMUX_MOBILE_RELAY_RATE_LIMIT_ID,
  });
  if (limited) return limited;

  const secret = env.CMUX_MOBILE_RELAY_TICKET_SECRET;
  if (!secret) return jsonResponse({ error: "relay_not_configured" }, 503);

  // Native-only: the relay is a device credential flow, never a browser one.
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const raw = await request.text();
  if (raw.length > MAX_REQUEST_BYTES) return jsonResponse({ error: "request_too_large" }, 413);
  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(raw);
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const body = parseBody(parsedJson);
  if (!body) return jsonResponse({ error: "invalid_request" }, 400);
  if (body.role === "host" && body.deviceId !== body.hostDeviceId) {
    return jsonResponse({ error: "host_device_mismatch" }, 400);
  }

  // The host device must be registered by this user (any of their teams).
  const owned = await cloudDb()
    .select({ id: devices.id })
    .from(devices)
    .where(and(eq(devices.deviceUuid, body.hostDeviceId), eq(devices.userId, user.id)))
    .limit(1);
  if (owned.length === 0) return jsonResponse({ error: "host_not_registered" }, 403);

  const nowMs = Date.now();
  const ticket = await mintTicket(secret, {
    userId: user.id,
    hostDeviceId: body.hostDeviceId,
    deviceId: body.deviceId,
    role: body.role,
    nowMs,
  });

  return jsonResponse({
    ticket,
    relayUrl: env.CMUX_MOBILE_RELAY_URL ?? DEFAULT_RELAY_URL,
    expiresAt: Math.floor(nowMs / 1000) + TICKET_TTL_SECONDS,
    protocolVersion: PROTOCOL_VERSION,
  });
}
