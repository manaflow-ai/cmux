import { timingSafeEqual } from "node:crypto";
import { eq } from "drizzle-orm";
import { cloudDb } from "@/db/client";
import { cloudVms } from "@/db/schema";
import { hasBlockingAccountDeletionIdentity } from "@/services/account/deletionLock";
import {
  NativeRelayConfigError,
  deriveNativeRelayBootstrapToken,
  nativeRelayRegisterTicket,
  nativeRelayShardsForVm,
  readNativeRelayConfig,
  shardById,
} from "@/services/vms/nativeRelay";

const VM_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHARD_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ACTIVE_VM_STATUSES = new Set(["provisioning", "running", "paused"]);

/**
 * Guest-only endpoint. The daemon calls this command endpoint before each
 * Register handshake. It is deliberately separate from Stack-authenticated
 * user routes: the bearer is a deterministic credential for this VM row, and
 * the database status and account-deletion checks remain authoritative.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  let config;
  try {
    config = readNativeRelayConfig();
  } catch (error) {
    if (error instanceof NativeRelayConfigError) {
      console.error("native relay ticket configuration is invalid");
    } else {
      console.error("native relay ticket configuration could not be loaded");
    }
    return unavailableResponse();
  }
  if (!config) return unavailableResponse();

  const { id } = await params;
  const vmId = id.trim();
  const shardId = new URL(request.url).searchParams.get("shard")?.trim() ?? "";
  if (!VM_ID_PATTERN.test(vmId) || !SHARD_ID_PATTERN.test(shardId)) {
    return notFoundResponse();
  }

  const supplied = bearerToken(request.headers.get("authorization"));
  const expected = deriveNativeRelayBootstrapToken(vmId, config.bootstrapSecret);
  if (!constantTimeEqual(supplied, expected)) return new Response(null, { status: 401 });

  // Check the shard assignment before querying the VM. This keeps the route
  // contract bounded and prevents a token for one VM from being used to probe
  // arbitrary shard configuration.
  if (!shardById(config, shardId) || !nativeRelayShardsForVm(vmId, config).some((shard) => shard.id === shardId)) {
    return notFoundResponse();
  }

  try {
    const db = cloudDb();
    const [vm] = await db
      .select({ id: cloudVms.id, userId: cloudVms.userId, status: cloudVms.status })
      .from(cloudVms)
      .where(eq(cloudVms.id, vmId))
      .limit(1);
    if (!vm || !ACTIVE_VM_STATUSES.has(vm.status)) return notFoundResponse();
    if (await hasBlockingAccountDeletionIdentity(db, [vm.userId])) return notFoundResponse();

    const minted = nativeRelayRegisterTicket({
      vmId,
      shardId,
      config,
    });
    return new Response(minted.ticket, {
      status: 200,
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-store, no-cache, max-age=0",
        pragma: "no-cache",
      },
    });
  } catch (error) {
    // Do not include the VM id, shard, or database text in the response. The
    // guest retries; operators get one coarse signal without credential data.
    console.error("native relay ticket issuance failed", {
      failure: error instanceof NativeRelayConfigError ? "configuration" : "database_or_signing",
    });
    return unavailableResponse();
  }
}

function bearerToken(value: string | null): string {
  const trimmed = value?.trim() ?? "";
  if (!trimmed.toLowerCase().startsWith("bearer ")) return "";
  return trimmed.slice("bearer ".length).trim();
}

function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "utf8");
  const rightBytes = Buffer.from(right, "utf8");
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

function unavailableResponse(): Response {
  return new Response(null, { status: 503, headers: { "cache-control": "no-store" } });
}

function notFoundResponse(): Response {
  return new Response(null, { status: 404, headers: { "cache-control": "no-store" } });
}
