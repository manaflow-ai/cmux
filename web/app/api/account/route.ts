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
    await deleteCmuxOwnedAccountRows(user.id);
    await stackUser.delete();
    return jsonResponse({ ok: true, destroyedVms });
  } catch (error) {
    console.error("account.delete.failed", error);
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
