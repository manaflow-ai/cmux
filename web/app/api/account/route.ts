import { and, eq, isNull, or } from "drizzle-orm";

import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { cloudDb } from "../../../db/client";
import {
  cloudVmBaseEvents,
  cloudVmBases,
  cloudVmLeases,
  cloudVmNotificationDeliveries,
  cloudVmNotificationEvents,
  cloudVmSessions,
  cloudVmUsageEvents,
  cloudVms,
  deviceTokens,
  devices,
  notificationSendEvents,
  vaultCliAuthRequests,
  vaultSessions,
  vaultUploadGrants,
  vaultUploadTombstones,
} from "../../../db/schema";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { destroyVm, listUserVms, runVmWorkflow } from "../../../services/vms/workflows";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type DeletableStackUser = {
  readonly id: string;
  readonly delete: () => Promise<void>;
};

export async function DELETE(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const stackUser = await currentDeletableStackUser(request);
  if (!stackUser || stackUser.id !== user.id) return unauthorized();

  try {
    const destroyedVms = await destroyPersonalCloudVms(user.id);
    // Delete cmux-owned data before the Stack user so a Stack-side failure does
    // not strand retained app data behind an account the user can no longer use.
    // These deletes are idempotent, so the same signed-in user can retry the
    // final Stack deletion when the distinct response below is returned.
    await deleteCmuxOwnedAccountRows(user.id);
    try {
      await stackUser.delete();
    } catch (error) {
      logAccountDeleteError("account.delete.stack_user_failed_after_data_delete", error);
      return jsonResponse({
        error: "account_stack_delete_failed_after_data_delete",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    return jsonResponse({ ok: true, destroyedVms });
  } catch (error) {
    logAccountDeleteError("account.delete.failed", error);
    return jsonResponse({ error: "account_delete_failed" }, 500);
  }
}

async function currentDeletableStackUser(request: Request): Promise<DeletableStackUser | null> {
  if (!isStackConfigured()) return null;

  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");
  if (!authHeader?.toLowerCase().startsWith("bearer ") || !refreshHeader) return null;

  const accessToken = authHeader.slice("bearer ".length).trim();
  const refreshToken = refreshHeader.trim();
  if (!accessToken || !refreshToken) return null;

  const user = await getStackServerApp().getUser({
    tokenStore: { accessToken, refreshToken },
  });
  if (!user || typeof (user as Partial<DeletableStackUser>).delete !== "function") return null;
  return user as DeletableStackUser;
}

async function destroyPersonalCloudVms(userId: string): Promise<number> {
  const vms = await runVmWorkflow(listUserVms(userId));
  for (const vm of vms) {
    await runVmWorkflow(destroyVm({ userId, providerVmId: vm.providerVmId }));
  }
  return vms.length;
}

async function deleteCmuxOwnedAccountRows(userId: string): Promise<void> {
  const db = cloudDb();
  await db.transaction(async (tx) => {
    await tx.delete(deviceTokens).where(eq(deviceTokens.userId, userId));
    await tx.delete(notificationSendEvents).where(eq(notificationSendEvents.userId, userId));

    await tx.delete(cloudVmNotificationDeliveries).where(eq(cloudVmNotificationDeliveries.userId, userId));
    await tx.delete(cloudVmNotificationEvents).where(eq(cloudVmNotificationEvents.userId, userId));
    await tx.delete(cloudVmUsageEvents).where(personalUsageScope(userId));
    await tx.delete(cloudVmLeases).where(eq(cloudVmLeases.userId, userId));
    await tx.delete(cloudVmSessions).where(eq(cloudVmSessions.userId, userId));
    await tx.delete(cloudVms).where(personalVmScope(userId));
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, userId));
    await tx.delete(cloudVmBases).where(and(
      eq(cloudVmBases.scopeType, "user"),
      eq(cloudVmBases.scopeId, userId),
    ));

    await tx.delete(devices).where(eq(devices.userId, userId));

    await tx.delete(vaultUploadGrants).where(eq(vaultUploadGrants.userId, userId));
    await tx.delete(vaultUploadTombstones).where(eq(vaultUploadTombstones.userId, userId));
    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, userId));
    await tx.delete(vaultSessions).where(eq(vaultSessions.userId, userId));
  });
}

function personalVmScope(userId: string) {
  return and(
    eq(cloudVms.userId, userId),
    or(isNull(cloudVms.billingTeamId), eq(cloudVms.billingTeamId, userId)),
  );
}

function personalUsageScope(userId: string) {
  return and(
    eq(cloudVmUsageEvents.userId, userId),
    or(isNull(cloudVmUsageEvents.billingTeamId), eq(cloudVmUsageEvents.billingTeamId, userId)),
  );
}

const SENSITIVE_ERROR_TEXT =
  /(srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,})/g;

function logAccountDeleteError(label: string, error: unknown): void {
  console.error(label, sanitizedErrorSummary(error));
}

function sanitizedErrorSummary(error: unknown): string {
  const name =
    error && typeof error === "object" && typeof (error as { name?: unknown }).name === "string"
      ? (error as { name: string }).name
      : typeof error;
  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return `${name}: ${message.replace(SENSITIVE_ERROR_TEXT, "[redacted]")}`;
}
