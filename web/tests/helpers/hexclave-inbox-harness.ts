import { expect } from "bun:test";
import { createHmac } from "node:crypto";

import { drainHexclaveInbox, type HexclaveInboxStore } from "../../services/auth/hexclave/inbox";
import type { HexclaveSyncDependencies } from "../../services/auth/hexclave/sync";
import { handleStackWebhook } from "../../services/auth/stackWebhook";
import { serverTeam, serverUser } from "./hexclave-fixtures";
import { FakeHexclave, MemoryInbox, MemoryMirror } from "./hexclave-memory";

/** A signed-delivery harness around the webhook handler and the inbox drain. */
const KEY = Buffer.from("hexclave-webhook-inbox-test-key-01234");
const SECRET = `whsec_${KEY.toString("base64")}`;
const NOW_SECONDS = 1_800_000_000;

export function userId(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
}
export function teamId(index: number): string {
  return `11111111-1111-4111-8111-${String(index).padStart(12, "0")}`;
}

export function inboxHarness(inbox: HexclaveInboxStore = new MemoryInbox()) {
  const hexclave = new FakeHexclave();
  const mirror = new MemoryMirror();
  const invalidated: string[] = [];
  let clockMs = NOW_SECONDS * 1_000;
  let drainsScheduled = 0;
  const sync: HexclaveSyncDependencies = {
    source: hexclave,
    store: mirror,
    revokeTeamMemberAccess: async () => {},
    revokeTeamAccess: async () => {},
    invalidateUser: async (id) => { invalidated.push(id); },
  };
  const post = (type: string, data: unknown, svixId: string) => {
    const body = JSON.stringify({ type, data });
    const signature = createHmac("sha256", KEY).update(`${svixId}.${NOW_SECONDS}.${body}`).digest("base64");
    return handleStackWebhook(new Request("https://cmux.test/api/webhooks/stack", {
      method: "POST",
      headers: { "content-type": "application/json", "svix-id": svixId, "svix-timestamp": String(NOW_SECONDS), "svix-signature": `v1,${signature}` },
      body,
    }), {
      webhookSecret: () => SECRET,
      nowSeconds: () => NOW_SECONDS,
      sync: () => sync,
      inbox: () => inbox,
      scheduleDrain: () => { drainsScheduled += 1; },
      log: () => {},
    });
  };
  const drain = (entityLimit = 10) => drainHexclaveInbox({ inbox, sync, entityLimit, now: () => new Date(clockMs) });
  return {
    hexclave,
    mirror,
    inbox,
    invalidated,
    post,
    drain,
    advance: (ms: number) => { clockMs += ms; },
    nowMs: () => clockMs,
    drainsScheduled: () => drainsScheduled,
  };
}

/** 300 deliveries: 120 users (2 events each, some 3) and 40 teams, in mixed order. */
export async function postBurst(harness: ReturnType<typeof inboxHarness>): Promise<string[]> {
  const ids: string[] = [];
  for (let index = 0; index < 120; index++) harness.hexclave.users.set(userId(index), serverUser({ id: userId(index) }));
  for (let index = 0; index < 40; index++) harness.hexclave.teams.set(teamId(index), serverTeam({ id: teamId(index) }));
  for (let index = 0; index < 300; index++) {
    const svixId = `msg_${String(index).padStart(3, "0")}`;
    const response = index % 7 === 3
      ? await harness.post("team.updated", serverTeam({ id: teamId(index % 40) }), svixId)
      : await harness.post(index % 2 ? "user.updated" : "user.created", serverUser({ id: userId(index % 120) }), svixId);
    expect(response.status).toBe(200);
    ids.push(svixId);
  }
  return ids;
}

