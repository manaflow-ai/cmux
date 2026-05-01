import { readFileSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";

import type { Provider as ApnProvider, ProviderOptions } from "apn";
import { NextResponse } from "next/server";
import { z } from "zod";

import { env } from "@/app/env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_DEVICE_TOKENS = 100;

const notificationsShape = z
  .object({
    bell: z.boolean().optional(),
    command_finished: z
      .object({
        exit_code: z.number().int().nullable().optional(),
      })
      .optional(),
    notification: z
      .object({
        title: z.string().optional(),
        body: z.string().optional(),
      })
      .optional(),
  })
  .passthrough();

const pushRequestSchema = z.object({
  device_tokens: z
    .array(z.string().trim().min(1).max(512))
    .min(1)
    .max(MAX_DEVICE_TOKENS),
  session_id: z.string().min(1),
  workspace_id: z.string().nullable().optional(),
  notifications: notificationsShape,
});

type PushRequest = z.infer<typeof pushRequestSchema>;

type ResolvedAlert = {
  title: string;
  body: string;
};

type ApnModule = typeof import("apn");

let apnModulePromise: Promise<ApnModule> | null = null;
let apnProvider: ApnProvider | null = null;
let apnProviderKey: string | null = null;

export async function POST(request: Request) {
  const bearerExpected = env.CMUX_DAEMON_PUSH_SECRET;
  if (!bearerExpected) {
    return jsonError("Push endpoint is not configured", 503);
  }

  const authHeader = request.headers.get("authorization") ?? "";
  if (!isValidBearer(authHeader, bearerExpected)) {
    return jsonError("Unauthorized", 401);
  }

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return jsonError("Invalid JSON payload", 400);
  }

  const parsed = pushRequestSchema.safeParse(rawBody);
  if (!parsed.success) {
    return jsonError("Invalid request payload", 400);
  }

  const payload = parsed.data;
  const alert = resolveAlert(payload);
  if (!alert) {
    // Nothing notifiable in the payload; nothing to do but ack.
    return jsonOk({ ok: true, delivered: 0, failed: 0, skipped: true });
  }

  const devMode =
    !env.APNS_TEAM_ID ||
    (!env.APNS_PRIVATE_KEY_BASE64 && !env.APNS_PRIVATE_KEY_PATH);

  if (devMode) {
    console.log("notifications.push.dev", {
      session_id: payload.session_id,
      workspace_id: payload.workspace_id ?? null,
      device_tokens: payload.device_tokens.map(redactToken),
      alert,
      notifications: payload.notifications,
    });
    return jsonOk({ ok: true, delivered: 0, failed: 0, dev: true });
  }

  let provider: ApnProvider;
  let apn: ApnModule;
  try {
    apn = await loadApnModule();
    provider = await getOrCreateProvider(apn);
  } catch (error) {
    console.error("notifications.push.provider_init_failed", error);
    return jsonError("APNs provider misconfigured", 500);
  }

  const bundleId = env.APNS_BUNDLE_ID;
  if (!bundleId) {
    return jsonError("APNS_BUNDLE_ID is required in production mode", 500);
  }

  const notification = new apn.Notification();
  notification.topic = bundleId;
  notification.alert = { title: alert.title, body: alert.body };
  notification.sound = "default";
  notification.priority = 10;
  notification.payload = {
    cmux: {
      session_id: payload.session_id,
      workspace_id: payload.workspace_id ?? null,
      notifications: payload.notifications,
    },
  };

  try {
    const response = await provider.send(notification, payload.device_tokens);
    if (response.failed.length > 0) {
      console.warn(
        "notifications.push.apns_failures",
        response.failed.map((failure) => ({
          device: redactToken(failure.device),
          status: failure.status,
          reason: failure.response?.reason,
          error: failure.error?.message,
        })),
      );
    }
    return jsonOk({
      ok: true,
      delivered: response.sent.length,
      failed: response.failed.length,
    });
  } catch (error) {
    console.error("notifications.push.apns_send_failed", error);
    return jsonError("Failed to deliver notification", 502);
  }
}

function resolveAlert(request: PushRequest): ResolvedAlert | null {
  const notifications = request.notifications;

  const note = notifications.notification;
  if (note && typeof note.title === "string" && typeof note.body === "string") {
    const title = note.title.trim();
    const body = note.body.trim();
    if (title.length > 0 || body.length > 0) {
      return { title, body };
    }
  }

  const commandFinished = notifications.command_finished;
  if (commandFinished) {
    const exitCode = commandFinished.exit_code;
    const body =
      typeof exitCode === "number" ? `Exit ${exitCode}` : "Completed";
    return { title: "Command finished", body };
  }

  if (notifications.bell === true) {
    return { title: "Terminal bell", body: "" };
  }

  return null;
}

function isValidBearer(headerValue: string, expected: string) {
  const match = headerValue.match(/^Bearer\s+(.+)$/i);
  if (!match) return false;
  const provided = match[1].trim();
  if (provided.length === 0) return false;
  const providedBuf = Buffer.from(provided, "utf8");
  const expectedBuf = Buffer.from(expected, "utf8");
  if (providedBuf.length !== expectedBuf.length) return false;
  return timingSafeEqual(providedBuf, expectedBuf);
}

function loadApnModule(): Promise<ApnModule> {
  if (!apnModulePromise) {
    apnModulePromise = import("apn");
  }
  return apnModulePromise;
}

async function getOrCreateProvider(apn: ApnModule): Promise<ApnProvider> {
  const teamId = env.APNS_TEAM_ID;
  const keyId = env.APNS_KEY_ID;
  if (!teamId || !keyId) {
    throw new Error("APNS_TEAM_ID and APNS_KEY_ID are required");
  }

  const privateKey = loadPrivateKey();
  const production = env.APNS_PRODUCTION === "1";
  const cacheKey = [teamId, keyId, production ? "prod" : "sandbox"].join("|");

  if (apnProvider && apnProviderKey === cacheKey) {
    return apnProvider;
  }

  if (apnProvider) {
    apnProvider.shutdown();
    apnProvider = null;
    apnProviderKey = null;
  }

  const options: ProviderOptions = {
    token: {
      key: privateKey,
      keyId,
      teamId,
    },
    production,
  };
  apnProvider = new apn.Provider(options);
  apnProviderKey = cacheKey;
  return apnProvider;
}

function loadPrivateKey(): string {
  const base64 = env.APNS_PRIVATE_KEY_BASE64;
  if (base64 && base64.length > 0) {
    const decoded = Buffer.from(base64, "base64").toString("utf8");
    if (decoded.length === 0) {
      throw new Error("APNS_PRIVATE_KEY_BASE64 decoded to empty string");
    }
    return decoded;
  }

  const path = env.APNS_PRIVATE_KEY_PATH;
  if (path && path.length > 0) {
    return readFileSync(path, "utf8");
  }

  throw new Error(
    "APNS private key missing (set APNS_PRIVATE_KEY_BASE64 or APNS_PRIVATE_KEY_PATH)",
  );
}

function redactToken(token: string) {
  if (token.length <= 8) return "***";
  return `${token.slice(0, 4)}...${token.slice(-4)}`;
}

function jsonOk(body: Record<string, unknown>) {
  return NextResponse.json(body, {
    headers: {
      "Cache-Control": "no-store",
    },
  });
}

function jsonError(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
}
