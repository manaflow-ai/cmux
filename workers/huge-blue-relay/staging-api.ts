/** Isolated internal staging HTTP harness: uses the same mutation handler and
 * composition as Next, but a disposable service principal instead of Stack UI.
 * Never imported by the deployed Next app. Loopback-only, staging DB required.
 */
import { readFileSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import { createConfiguredPersistentWorkspaceService } from "../../web/services/vms/persistentWorkspaceComposition";
import { workspaceHttp, workspaceJson } from "../../web/services/vms/workspaceHttp";
import type { AuthedUser } from "../../web/services/vms/auth";

if (process.env.CMUX_STAGING_API !== "1" || !process.env.CMUX_STAGING_BRANCH?.startsWith("cmux-broker-staging-")) {
  throw new Error("isolated staging API requires a disposable branch receipt");
}
const secret = readFileSync(process.env.CMUX_STAGING_API_TOKEN_FILE!, "utf8").trim();
if (secret.length < 32) throw new Error("staging API token is invalid");
const ownerId = process.env.CMUX_STAGING_OWNER_ID!;
const tenantId = process.env.CMUX_STAGING_TENANT_ID!;
if (!ownerId || !tenantId) throw new Error("staging principal is required");
const user = { id: ownerId, billingTeamId: tenantId } as AuthedUser;
const service = createConfiguredPersistentWorkspaceService({
  user, provider: "huge-blue",
  entitlements: { planId: "internal", billingCustomerType: "team", billingTeamId: tenantId, maxActiveVms: 1, resourcePool: null },
});
Bun.serve({
  hostname: "127.0.0.1", port: Number(process.env.CMUX_STAGING_API_PORT ?? 1340),
  fetch(request) {
    const supplied = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
    if (Buffer.byteLength(supplied) !== Buffer.byteLength(secret) || !timingSafeEqual(Buffer.from(supplied), Buffer.from(secret))) {
      return workspaceJson({ error: "unauthorized" }, 401);
    }
    const path = new URL(request.url).pathname;
    if (path === "/healthz") return workspaceJson({ ok: true, sha: process.env.CMUX_SOURCE_SHA });
    const match = /^\/api\/workspaces(?:\/([a-zA-Z0-9_-]+))?$/.exec(path);
    if (!match) return workspaceJson({ error: "not_found" }, 404);
    return workspaceHttp(request, service, { ownerId, tenantId }, match[1]);
  },
});
console.log(JSON.stringify({ event: "staging_api_ready", ownerId, tenantId, sha: process.env.CMUX_SOURCE_SHA }));
