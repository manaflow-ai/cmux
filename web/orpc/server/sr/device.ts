import { ORPCError } from "@orpc/server";
import { eq, lt } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { srDeviceCodes } from "../../../db/schema";
import {
  generateDeviceCode,
  generateUserCode,
  hashDeviceCode,
} from "../../../services/subrouter/vaultCrypto";
import { os } from "../base";
import {
  srDevicePollInputSchema,
  srDevicePollOutputSchema,
  srDeviceStartOutputSchema,
} from "./schemas";

// Device-code login, chosen over a localhost redirect because the CLI routinely
// runs over SSH and inside containers where no browser can reach 127.0.0.1.

const DEVICE_CODE_TTL_SECONDS = 900;
const POLL_INTERVAL_SECONDS = 5;

// start is deliberately unauthenticated: it is the entry point for a client that
// has no credentials yet. It hands back an opaque device code plus a short human
// code, and grants nothing until a signed-in human approves it in a browser.
export const srDeviceStartProcedure = os
  .route({
    method: "POST",
    path: "/sr/device/start",
    operationId: "sr.device.start",
    summary: "Begin a device-code login",
    description:
      "Issues a device code for the CLI and a short user code for the human to approve in a browser. Grants no access until approved.",
    tags: ["Subrouter"],
    successStatus: 200,
  })
  .output(srDeviceStartOutputSchema)
  .handler(async () => {
    const db = cloudDb();
    // Sweep expired rows opportunistically so this table cannot grow unbounded
    // without a separate cron.
    await db.delete(srDeviceCodes).where(lt(srDeviceCodes.expiresAt, new Date()));

    const deviceCode = generateDeviceCode();
    const userCode = generateUserCode();
    const expiresAt = new Date(Date.now() + DEVICE_CODE_TTL_SECONDS * 1000);

    await db.insert(srDeviceCodes).values({
      userCode,
      deviceCodeHash: hashDeviceCode(deviceCode),
      expiresAt,
    });

    return {
      userCode,
      deviceCode,
      verificationUri: "https://cmux.com/sr/device",
      expiresInSeconds: DEVICE_CODE_TTL_SECONDS,
      intervalSeconds: POLL_INTERVAL_SECONDS,
    };
  });

// poll is also unauthenticated: possession of the device code is the only proof
// the CLI has, and the code is compared by digest so a database dump cannot be
// replayed to complete someone else's pending login.
export const srDevicePollProcedure = os
  .route({
    method: "POST",
    path: "/sr/device/poll",
    operationId: "sr.device.poll",
    summary: "Poll a pending device-code login",
    description:
      "Returns pending until a signed-in human approves the matching user code, then returns the approved team once.",
    tags: ["Subrouter"],
    successStatus: 200,
  })
  .input(srDevicePollInputSchema)
  .output(srDevicePollOutputSchema)
  .handler(async ({ input }) => {
    const db = cloudDb();
    const rows = await db
      .select()
      .from(srDeviceCodes)
      .where(eq(srDeviceCodes.deviceCodeHash, hashDeviceCode(input.deviceCode)))
      .limit(1);

    const row = rows[0];
    if (!row) {
      // An unknown code is indistinguishable from an expired one on purpose:
      // neither confirms whether a code ever existed.
      return { status: "expired" as const, teamId: null, userId: null };
    }
    if (row.expiresAt.getTime() <= Date.now()) {
      await db.delete(srDeviceCodes).where(eq(srDeviceCodes.id, row.id));
      return { status: "expired" as const, teamId: null, userId: null };
    }
    if (!row.approvedAt || !row.teamId) {
      return { status: "pending" as const, teamId: null, userId: null };
    }

    // Single-use: consuming the row means a captured device code cannot be
    // redeemed twice.
    await db.delete(srDeviceCodes).where(eq(srDeviceCodes.id, row.id));
    return {
      status: "approved" as const,
      teamId: row.teamId,
      userId: row.userId,
    };
  });

// approveDeviceCode is called by the signed-in browser session, not the CLI. It
// is exported for the approval route rather than exposed as a public procedure.
export async function approveDeviceCode(
  userCode: string,
  userId: string,
  teamId: string,
): Promise<void> {
  const db = cloudDb();
  const rows = await db
    .select()
    .from(srDeviceCodes)
    .where(eq(srDeviceCodes.userCode, userCode.trim().toUpperCase()))
    .limit(1);

  const row = rows[0];
  if (!row || row.expiresAt.getTime() <= Date.now()) {
    throw new ORPCError("NOT_FOUND", { message: "That code is not valid or has expired" });
  }
  await db
    .update(srDeviceCodes)
    .set({ approvedAt: new Date(), userId, teamId })
    .where(eq(srDeviceCodes.id, row.id));
}
