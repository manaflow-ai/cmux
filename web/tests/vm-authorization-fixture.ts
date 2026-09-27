import { randomBytes } from "node:crypto";
import { signVmAuthorization } from "../services/coderouter/vmAuthorization";

process.env.CMUX_VM_AUTH_SIGNING_KEY = randomBytes(32).toString("base64url");
process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = "test-v1";
delete process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS;

export async function vmToken(vmId = "vm-1", teamId = "team-1", ownerId = "user-1") {
  return await signVmAuthorization({ vmId, teamId, ownerId, expiresAt: new Date(Date.now() + 60_000) });
}
