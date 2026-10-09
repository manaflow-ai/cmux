import production, { AccountControl as ProductionAccountControl, TeamControl as ProductionTeamControl, UserUsage as ProductionUserUsage } from "../src/index";
import type { DeviceDescriptor } from "../src/contracts/common";
import { TeamStore } from "../src/storage/team-store";

/**
 * Multi-team account directory fixture. Routing, authentication, team and
 * account objects are production code. Two test-only controls make two runs
 * of the same scenario byte-comparable: a frozen clock and counter UUIDs.
 */
const FIXED_NOW_MS = 1_900_000_000_000;
Date.now = () => FIXED_NOW_MS; // Must match FIXED_NOW in account-runtime.test.ts.
let uuid = 0;
crypto.randomUUID = () => `00000000-0000-4000-8000-${(++uuid).toString(16).padStart(12, "0")}` as `${string}-${string}-${string}-${string}-${string}`;

export class TestTeamControl extends ProductionTeamControl {
  /** Test-only enrollment through the production commit path. Authority leases come from real ticketed team requests. */
  seed(teamId: string, device: DeviceDescriptor): string {
    const store = new TeamStore(this.ctx.storage, { environment: this.env.ENVIRONMENT, projectId: this.env.STACK_PROJECT_ID, teamId }, { initialize: false });
    const now = Math.floor(FIXED_NOW_MS / 1000);
    store.issueChallenge(device.identity, { challengeId: `seed-${device.identity.deviceId}`, nonceHash: "seed-nonce", payloadHash: "seed-payload", issuedAt: now - 100, expiresAt: now + 1700 });
    const record = store.commitRegistration({
      descriptor: device, challengeId: `seed-${device.identity.deviceId}`, nonceHash: "seed-nonce", payloadHash: "seed-payload",
      requestId: `seed-${device.identity.deviceId}`, requestHash: `seed-${device.identity.deviceId}`, now: now - 100,
    });
    return record.device.deviceRecordId;
  }
}
export class TestUserUsage extends ProductionUserUsage {}
export class TestAccountControl extends ProductionAccountControl {}

export default production;
