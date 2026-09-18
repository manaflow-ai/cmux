// Register / unregister an iOS APNs device token for push notifications.
// Auth: Stack Bearer from the native client. A row only exists after the
// user explicitly opts in on their device, so presence == "wants phone pushes".

import crypto from "node:crypto";
import { decodeJwt } from "jose";
import { and, count, eq, gt, isNull, ne, or, sql } from "drizzle-orm";
import { env } from "../../env";
import { cloudDb } from "../../../db/client";
import { deviceTokenRevocations, deviceTokens } from "../../../db/schema";
import { resolveApnsProviderConfiguration } from "../../../services/apns/config";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { parseNativeStackTokens, unauthorized, verifyRequest } from "../../../services/vms/auth";
import { recordApnsEncryptionKeyRejection, withApnsApiRoute } from "../../../services/apns/routeHandler";
import { enforceNativeIngressRateLimit } from "../../../services/nativeIngressRateLimit";
import { authProviderErrorResponse } from "../../../services/vms/authErrors";
import {
  MAX_DEVICE_TOKENS_PER_ACCOUNT,
  MAX_DEVICE_TOKENS_PER_USER,
  MAX_PUSH_REQUEST_BYTES,
  normalizeApnsBundle,
  readBoundedJsonObject,
} from "../../../services/apns/routePolicy";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../../../services/account/deletionLock";
import { waitForDeviceDeliveryTarget } from "../../../services/apns/deviceDeliveryLease";


const HEX_TOKEN = /^[0-9a-fA-F]{64,200}$/;
const SAFE_KEY_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const SAFE_INSTALLATION_ID = /^[A-Za-z0-9-]{16,128}$/;
const BASE64_KEY = /^[A-Za-z0-9+/]{43}=?$/;

export async function GET(request: Request): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try { user = await verifyRequest(request, { allowCookie: false }); }
  catch (error) { return authProviderErrorResponse(error, "device-tokens.get.auth"); }
  if (!user) return unauthorized();
  const bundleId = request.headers.get("x-cmux-app-namespace")?.trim()
    || new URL(request.url).searchParams.get("bundleId")?.trim() || "";
  const bundle = normalizeApnsBundle(bundleId);
  if (!bundle) return jsonResponse({ error: "invalid_bundle_id" }, 400);
  const rows = await cloudDb().select({
    accountID: deviceTokens.userId,
    installationID: deviceTokens.installationId,
    keyID: deviceTokens.pushKeyId,
    publicKey: deviceTokens.pushPublicKey,
    bundleID: deviceTokens.bundleId,
  }).from(deviceTokens).where(and(
    eq(deviceTokens.userId, user.id),
    eq(deviceTokens.bundleId, bundle.bundleId),
    eq(deviceTokens.platform, "ios"),
    isNull(deviceTokens.revokedAt),
  ));
  return jsonResponse({ recipients: rows.filter((row) => row.publicKey && row.installationID !== "legacy") });
}

export async function POST(request: Request): Promise<Response> {
  const rateLimitResponse = await enforceNativeIngressRateLimit({
    request,
    route: "device-tokens.post",
    ruleId: env.CMUX_PUSH_RATE_LIMIT_ID,
  });
  if (rateLimitResponse) return rateLimitResponse;
  return withApnsApiRoute(request, "/api/device-tokens", "register", async () => registerDeviceToken(request));
}

async function registerDeviceToken(request: Request): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verifyRequest(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, "device-tokens.post.auth");
  }
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);

  const input = parseRegistrationInput(request, body.value);
  if (!input.ok) return input.response;
  const { deviceToken, bundle, platform, installationId, pushKeyId, pushPublicKey, isLegacy } = input.value;
  const authSessionFingerprint = requestAuthSessionFingerprint(request);

  const db = cloudDb();

  let registration: {
    limitReached: boolean;
    deliveryBusyRetryAfterSeconds?: number;
    conflict?: boolean;
    authRevoked?: boolean;
  };
  try {
    // The transaction deliberately keeps the lock, conflict, capacity, and
    // upsert decisions together so registration remains atomic.
    // oxlint-disable-next-line complexity
    registration = await db.transaction(async (tx) => {
      await assertAccountDeletionUserMutationAllowed(tx, user.id);
      await lockDeviceTokenMutations(tx, user.id);

      let existingInstallation:
        | {
            id: string;
            userId: string;
            deliveryLeaseUntil: Date | null;
            pushKeyId: string;
            pushPublicKey: string | null;
            revokedAt: Date | null;
          }
        | undefined;
      if (!isLegacy) {
        [existingInstallation] = await tx
          .select({
            id: deviceTokens.id,
            userId: deviceTokens.userId,
            deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
            pushKeyId: deviceTokens.pushKeyId,
            pushPublicKey: deviceTokens.pushPublicKey,
            revokedAt: deviceTokens.revokedAt,
          })
          .from(deviceTokens)
          .where(and(
            eq(deviceTokens.bundleId, bundle.bundleId),
            eq(deviceTokens.installationId, installationId),
          ))
          .limit(1)
          .for("update");
      }

      const [existingToken] = await tx
        .select({
          id: deviceTokens.id,
          userId: deviceTokens.userId,
          bundleId: deviceTokens.bundleId,
          deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
          pushKeyId: deviceTokens.pushKeyId,
          pushPublicKey: deviceTokens.pushPublicKey,
          revokedAt: deviceTokens.revokedAt,
        })
        .from(deviceTokens)
        .where(and(
          eq(deviceTokens.bundleId, bundle.bundleId),
          eq(deviceTokens.deviceToken, deviceToken),
        ))
        .limit(1)
        .for("update");

      const deliveryLeaseUntilMs = Math.max(
        existingInstallation?.deliveryLeaseUntil?.getTime() ?? 0,
        existingToken?.deliveryLeaseUntil?.getTime() ?? 0,
      );
      const [sessionRevocation] = await tx
        .select({ id: deviceTokenRevocations.id })
        .from(deviceTokenRevocations)
        .where(and(
          eq(deviceTokenRevocations.userId, user.id),
          eq(deviceTokenRevocations.deviceToken, deviceToken),
          eq(deviceTokenRevocations.bundleId, bundle.bundleId),
          eq(deviceTokenRevocations.authSessionFingerprint, authSessionFingerprint),
          gt(deviceTokenRevocations.expiresAt, new Date()),
        ))
        .limit(1);
      if (sessionRevocation) {
        return { limitReached: false, authRevoked: true };
      }
      if (deliveryLeaseUntilMs > Date.now()) {
        return {
          limitReached: false,
          deliveryBusyRetryAfterSeconds: Math.max(
            1,
            Math.ceil((deliveryLeaseUntilMs - Date.now()) / 1_000),
          ),
        };
      }

      if (
        (existingInstallation && existingInstallation.userId !== user.id)
        || (existingToken && existingToken.userId !== user.id)
      ) {
        return { limitReached: false, conflict: true };
      }

      const ownedInstallation = existingInstallation?.userId === user.id;
      const ownedToken = existingToken?.userId === user.id;
      if (!ownedInstallation && !ownedToken) {
        const [accountRegistrationCount] = await tx
          .select({ total: count() })
          .from(deviceTokens)
          .where(and(
            eq(deviceTokens.userId, user.id),
            isNull(deviceTokens.revokedAt),
            or(
              ne(deviceTokens.bundleId, bundle.bundleId),
              ne(deviceTokens.deviceToken, deviceToken),
            ),
          ));
        if (
          Number(accountRegistrationCount?.total ?? 0)
          >= MAX_DEVICE_TOKENS_PER_ACCOUNT
        ) {
          return { limitReached: true };
        }
        const [registrationCount] = await tx
          .select({ total: count() })
          .from(deviceTokens)
          .where(and(
            eq(deviceTokens.userId, user.id),
            eq(deviceTokens.bundleId, bundle.bundleId),
            isNull(deviceTokens.revokedAt),
            ne(deviceTokens.deviceToken, deviceToken),
          ));
        if (Number(registrationCount?.total ?? 0) >= MAX_DEVICE_TOKENS_PER_USER) {
          // Never guess that an old-looking token is dead. Only an APNs
          // terminal response proves that and the send route prunes it there.
          // Re-registering a known current token still succeeds above; a new
          // token receives a typed repair rather than silently evicting a
          // potentially live device.
          return { limitReached: true };
        }
      }

      if (ownedToken && existingToken && ownedInstallation
          && existingInstallation && existingToken.id !== existingInstallation.id) {
        await tx.delete(deviceTokens).where(eq(deviceTokens.id, existingToken.id));
      }

      const rowToUpdate = existingInstallation ?? existingToken;
      if (rowToUpdate) {
        await tx
          .update(deviceTokens)
          .set({
            userId: user.id,
            deviceToken,
            bundleId: bundle.bundleId,
            environment: bundle.environment,
            platform,
            installationId: isLegacy ? "legacy" : installationId,
            pushKeyId: isLegacy ? "legacy" : pushKeyId,
            pushPublicKey: isLegacy ? null : pushPublicKey,
            revokedAt: null,
            updatedAt: new Date(),
          })
          .where(and(
            eq(deviceTokens.id, rowToUpdate.id),
            sql`not exists (
              select 1
              from device_token_revocations
              where user_id = ${user.id}
                and device_token = ${deviceToken}
                and bundle_id = ${bundle.bundleId}
                and auth_session_fingerprint = ${authSessionFingerprint}
                and expires_at > now()
            )`,
          ));
      } else {
        await tx.insert(deviceTokens).values({
          userId: user.id,
          deviceToken,
          bundleId: bundle.bundleId,
          environment: bundle.environment,
          platform,
          installationId: isLegacy ? "legacy" : installationId,
          pushKeyId: isLegacy ? "legacy" : pushKeyId,
          pushPublicKey: isLegacy ? null : pushPublicKey,
        });
      }

      return { limitReached: false };
    });
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) {
      return jsonResponse({ error: "account_deletion_in_progress" }, 409);
    }
    throw error;
  }

  return registrationResponse(registration);
}

type RegistrationInput = {
  deviceToken: string;
  bundle: NonNullable<ReturnType<typeof normalizeApnsBundle>>;
  platform: string;
  installationId: string;
  pushKeyId: string;
  pushPublicKey: string;
  isLegacy: boolean;
};

function parseRegistrationInput(
  request: Request,
  body: Record<string, unknown>,
): { ok: true; value: RegistrationInput } | { ok: false; response: Response } {
  const deviceToken = typeof body.deviceToken === "string" ? body.deviceToken.trim().toLowerCase() : "";
  const bundleId = typeof body.bundleId === "string" ? body.bundleId.trim() : "";
  const clientNamespace = request.headers.get("x-cmux-app-namespace") ?? "legacy";
  const platform = typeof body.platform === "string" ? body.platform.trim() || "ios" : "ios";
  const installationId = typeof body.installationId === "string" ? body.installationId.trim() : "";
  const pushKeyId = typeof body.pushKeyId === "string" ? body.pushKeyId.trim() : "";
  const pushPublicKey = typeof body.pushPublicKey === "string" ? body.pushPublicKey.trim() : "";
  const bundle = normalizeApnsBundle(bundleId);
  if (!HEX_TOKEN.test(deviceToken)) return { ok: false, response: jsonResponse({ error: "invalid_device_token" }, 400) };
  if (!bundle) return { ok: false, response: jsonResponse({ error: "invalid_bundle_id" }, 400) };
  if (!/^[A-Za-z0-9._:-]{1,255}$/.test(clientNamespace) || (clientNamespace !== "legacy" && clientNamespace !== bundle.bundleId)) {
    return { ok: false, response: jsonResponse({ error: "client_namespace_mismatch" }, 403) };
  }
  if (platform !== "ios") return { ok: false, response: jsonResponse({ error: "invalid_platform" }, 400) };
  if (clientNamespace === "legacy" && !installationId && !pushKeyId && !pushPublicKey) {
    return {
      ok: true,
      value: {
        deviceToken,
        bundle,
        platform,
        installationId: "legacy",
        pushKeyId: "legacy",
        pushPublicKey: "",
        isLegacy: true,
      },
    };
  }
  const pushKeys = parsePushKeyFields(installationId, pushKeyId, pushPublicKey);
  if (!pushKeys) {
    recordApnsEncryptionKeyRejection();
    return { ok: false, response: jsonResponse({ error: "invalid_push_key", action: "complete_secure_pairing" }, 400) };
  }
  return { ok: true, value: { deviceToken, bundle, platform, ...pushKeys } };
}

function parsePushKeyFields(
  installationId: string,
  pushKeyId: string,
  pushPublicKey: string,
): Pick<RegistrationInput, "installationId" | "pushKeyId" | "pushPublicKey" | "isLegacy"> | null {
  if (!SAFE_INSTALLATION_ID.test(installationId) || !SAFE_KEY_ID.test(pushKeyId) || !BASE64_KEY.test(pushPublicKey)) {
    return null;
  }
  return { installationId, pushKeyId, pushPublicKey, isLegacy: false };
}

function registrationResponse(registration: {
  limitReached: boolean;
  deliveryBusyRetryAfterSeconds?: number;
  conflict?: boolean;
  authRevoked?: boolean;
}): Response {
  if (registration.limitReached) {
    return jsonResponse({
      error: "too_many_devices",
      limit: MAX_DEVICE_TOKENS_PER_USER,
      action: "disable_push_on_another_device",
    }, 429);
  }
  if (registration.authRevoked) {
    return jsonResponse({ error: "push_registration_revoked" }, 409);
  }
  if (registration.conflict) return jsonResponse({ error: "push_registration_conflict" }, 409);
  if (registration.deliveryBusyRetryAfterSeconds != null) {
    return new Response(JSON.stringify({
      error: "push_delivery_in_progress",
      retryAfterSeconds: registration.deliveryBusyRetryAfterSeconds,
    }), {
      status: 409,
      headers: {
        "content-type": "application/json",
        "retry-after": String(registration.deliveryBusyRetryAfterSeconds),
      },
    });
  }
  return jsonResponse({
    ok: true,
    pushServiceConfigured: resolveApnsProviderConfiguration(
      env.CMUX_APNS_KEY_P8,
      env.CMUX_APNS_KEY_ID,
      env.CMUX_APNS_TEAM_ID,
    ) !== null,
  });
}

export async function DELETE(request: Request): Promise<Response> {
  const rateLimitResponse = await enforceNativeIngressRateLimit({
    request,
    route: "device-tokens.delete",
    ruleId: env.CMUX_PUSH_RATE_LIMIT_ID,
  });
  if (rateLimitResponse) return rateLimitResponse;
  return withApnsApiRoute(request, "/api/device-tokens", "delete", async () => deleteDeviceToken(request));
}

async function deleteDeviceToken(request: Request): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verifyRequest(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, "device-tokens.delete.auth");
  }
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  const revokeSession = body.value.revokeSession === true
    || body.value.revokeSession === "true";
  const authSessionFingerprint = revokeSession
    ? requestAuthSessionFingerprint(request)
    : null;
  const deviceToken = typeof body.value.deviceToken === "string" ? body.value.deviceToken.trim().toLowerCase() : "";
  const bodyBundleId =
    typeof body.value.bundleId === "string"
      ? body.value.bundleId.trim()
      : "";
  const headerNamespace = request.headers.get("x-cmux-app-namespace");
  const clientNamespace = headerNamespace ?? bodyBundleId;
  if (!deviceToken) return jsonResponse({ error: "missing_device_token" }, 400);
  if (!HEX_TOKEN.test(deviceToken)) return jsonResponse({ error: "invalid_device_token" }, 400);
  if (clientNamespace && (
    !normalizeApnsBundle(clientNamespace) ||
    (headerNamespace !== null &&
      bodyBundleId !== "" &&
      headerNamespace !== bodyBundleId)
  )) {
    return jsonResponse({ error: "invalid_client_namespace" }, 400);
  }

  const db = cloudDb();
  const deletion = await db.transaction(async (tx) => {
    await lockDeviceTokenMutations(tx, user.id);
    const matches = await tx
      .select({
        id: deviceTokens.id,
        bundleId: deviceTokens.bundleId,
        deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
        deliveryStartedAt: deviceTokens.deliveryStartedAt,
      })
      .from(deviceTokens)
      .where(clientNamespace
        ? and(
          eq(deviceTokens.deviceToken, deviceToken),
          eq(deviceTokens.userId, user.id),
          eq(deviceTokens.bundleId, clientNamespace),
        )
        : and(
          eq(deviceTokens.deviceToken, deviceToken),
          eq(deviceTokens.userId, user.id),
        ))
      .limit(clientNamespace ? 1 : 2)
      .for("update");
    if (!clientNamespace && matches.length > 1) {
      return { outcome: "ambiguous" as const };
    }
    const existingToken = matches[0];
    return applyDeviceTokenDeletion(tx, {
      userId: user.id,
      deviceToken,
      clientNamespace,
      revokeSession,
      authSessionFingerprint,
      existingToken,
    });
  });
  if (deletion.outcome === "ambiguous") {
    return jsonResponse({ error: "ambiguous_legacy_device_token" }, 409);
  }
  if (deletion.waitForDeliveryTargetId) {
    await waitForDeviceDeliveryTarget(db, deletion.waitForDeliveryTargetId);
  }
  return jsonResponse({ ok: true });
}

type DeviceTokenDeletionTransaction =
  Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

async function lockDeviceTokenMutations(
  tx: DeviceTokenDeletionTransaction,
  userId: string,
): Promise<void> {
  await tx.execute(
    sql`select pg_advisory_xact_lock(hashtextextended(${userId}, 2))`,
  );
}

type DeviceTokenMatch = {
  readonly id: string;
  readonly bundleId: string;
  readonly deliveryLeaseUntil: Date | null;
  readonly deliveryStartedAt: Date | null;
};

async function applyDeviceTokenDeletion(
  tx: DeviceTokenDeletionTransaction,
  input: {
    readonly userId: string;
    readonly deviceToken: string;
    readonly clientNamespace: string | null;
    readonly revokeSession: boolean;
    readonly authSessionFingerprint: string | null;
    readonly existingToken: DeviceTokenMatch | undefined;
  },
): Promise<{
  readonly outcome: "deleted" | "revoked";
  readonly waitForDeliveryTargetId: string | null;
}> {
  const {
    userId,
    deviceToken,
    clientNamespace,
    revokeSession,
    authSessionFingerprint,
    existingToken,
  } = input;
  if (revokeSession && existingToken) {
    await tx
      .insert(deviceTokenRevocations)
      .values({
        userId,
        deviceToken,
        bundleId: existingToken.bundleId,
        authSessionFingerprint: authSessionFingerprint!,
        expiresAt: deviceTokenRevocationExpiresAt(),
      })
      .onConflictDoNothing();
    await tx
      .update(deviceTokens)
      .set({ revokedAt: new Date(), updatedAt: new Date() })
      .where(eq(deviceTokens.id, existingToken.id));
    return {
      outcome: "revoked",
      waitForDeliveryTargetId:
        existingToken.deliveryStartedAt != null
        || (existingToken.deliveryLeaseUntil?.getTime() ?? 0) > Date.now()
          ? existingToken.id
          : null,
    };
  }
  if ((existingToken?.deliveryLeaseUntil?.getTime() ?? 0) > Date.now()) {
    if (existingToken) {
      await tx
        .update(deviceTokens)
        .set({ revokedAt: new Date(), updatedAt: new Date() })
        .where(eq(deviceTokens.id, existingToken.id));
    }
    return {
      outcome: "revoked",
      waitForDeliveryTargetId: existingToken?.id ?? null,
    };
  }
  if (revokeSession && clientNamespace) {
    const bundle = normalizeApnsBundle(clientNamespace);
    if (bundle) {
      await tx
        .insert(deviceTokenRevocations)
        .values({
          userId,
          deviceToken,
          bundleId: bundle.bundleId,
          authSessionFingerprint: authSessionFingerprint!,
          expiresAt: deviceTokenRevocationExpiresAt(),
        })
        .onConflictDoNothing();
    }
  }
  if (existingToken) {
    await tx
      .delete(deviceTokens)
      .where(and(
        eq(deviceTokens.deviceToken, deviceToken),
        eq(deviceTokens.userId, userId),
        eq(deviceTokens.bundleId, existingToken.bundleId),
      ));
  }
  return { outcome: "deleted", waitForDeliveryTargetId: null };
}

function requestAuthSessionFingerprint(request: Request): string {
  const tokens = parseNativeStackTokens(request);
  if (!tokens) return "unknown";
  let sessionID: unknown;
  try {
    sessionID = decodeJwt(tokens.accessToken).refresh_token_id;
  } catch {
    sessionID = null;
  }
  if (typeof sessionID !== "string" || sessionID.length === 0) return "unknown";
  return crypto
    .createHash("sha256")
    .update("cmux-stack-session-v1\n" + sessionID)
    .digest("hex");
}

function deviceTokenRevocationExpiresAt(): Date {
  return new Date(Date.now() + 30 * 24 * 60 * 60 * 1_000);
}
