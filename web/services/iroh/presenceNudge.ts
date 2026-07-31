// Broker -> presence-worker wake-up hook.
//
// When a binding's lifecycle changes server-side (user revoke, slot
// reincarnation, stale-binding reap) the affected device would otherwise learn
// only on its next scheduled broker round trip (minutes, worst-case tens of
// minutes). The presence worker already carries a directed, device-scoped
// nudge channel (`POST /v1/presence/nudge`, kind `iroh-binding-changed`) that
// the Mac subscribes to; this module lets the broker fire that nudge.
//
// Delivery contract: STRICTLY best-effort acceleration. Absent configuration
// (`CMUX_PRESENCE_NUDGE_URL` + `CMUX_PRESENCE_NUDGE_SECRET`) it is a no-op;
// lookup or fetch failures are swallowed after a bounded (~2s) budget and
// logged as counts only. `bindingChanged` NEVER fails, so a presence-worker
// outage can never fail or delay a broker mutation beyond the budget.
//
// Team fan-out: the presence worker shards its Durable Objects by team id, and
// a Mac's directed socket lives in the DO of the team its auth session
// resolved (selected team, else sole team, else the solo-account user id).
// The broker only knows the Stack user id, so candidate team ids come from the
// device registry (`devices.team_id` rows the same physical device registered,
// which use the identical client-side team resolution) plus the user id as the
// solo-account fallback. Wrong-team candidates 404 in the worker (no owner pin
// in that DO), which is expected and not an error.

import * as Effect from "effect/Effect";
import { desc, inArray } from "drizzle-orm";
import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { devices } from "../../db/schema";

export const IROH_PRESENCE_NUDGE_KIND = "iroh-binding-changed";
export const IROH_PRESENCE_NUDGE_TIMEOUT_MS = 2_000;
/** Upper bound on events per call (the reaper can revoke hundreds in one cron
 * run). Excess events are dropped with a log line; the dropped devices still
 * converge on their normal cadence. */
export const IROH_PRESENCE_NUDGE_MAX_EVENTS = 128;
/** Candidate team DOs tried per event, beyond the user-id fallback. */
export const IROH_PRESENCE_NUDGE_MAX_TEAMS_PER_EVENT = 3;
const CANDIDATE_TEAM_ROW_LIMIT = 256;

export type IrohBindingNudgeEvent = {
  readonly userId: string;
  readonly deviceUuid: string;
  readonly tag: string;
};

export type IrohPresenceNudgeShape = {
  /** Fire-and-forget wake-up for each affected device. Never fails. */
  readonly bindingChanged: (
    events: readonly IrohBindingNudgeEvent[],
  ) => Effect.Effect<void>;
};

export type IrohPresenceNudgeCandidateTeamLookup = (
  events: readonly IrohBindingNudgeEvent[],
) => Promise<ReadonlyMap<string, readonly string[]>>;

export type IrohPresenceNudgeConfig = {
  /** Presence service origin, e.g. https://presence.cmux.dev. Defaults to
   * CMUX_PRESENCE_NUDGE_URL; absent = the whole hook is a no-op. */
  readonly baseUrl?: string;
  /** Shared server secret; sent as `x-cmux-nudge-secret`. Defaults to
   * CMUX_PRESENCE_NUDGE_SECRET; absent = no-op. */
  readonly secret?: string;
  readonly timeoutMs?: number;
  readonly fetchImpl?: typeof fetch;
  readonly lookupCandidateTeamIds?: IrohPresenceNudgeCandidateTeamLookup;
};

/** Map key for candidate-team lookup results. */
export function irohNudgeEventKey(event: Pick<IrohBindingNudgeEvent, "userId" | "deviceUuid">): string {
  return `${event.userId}\n${event.deviceUuid}`;
}

export function makeIrohPresenceNudge(
  config: IrohPresenceNudgeConfig = {},
): IrohPresenceNudgeShape {
  return {
    bindingChanged: (events) => Effect.promise(() =>
      deliverBindingChanged(config, events).catch(() => {
        // deliverBindingChanged already contains all expected failure handling;
        // this guard only catches programming defects so the contract holds.
        console.warn("iroh presence nudge failed", { failure: "unexpected" });
      })),
  };
}

export const irohPresenceNudgeLive: IrohPresenceNudgeShape = makeIrohPresenceNudge();

async function deliverBindingChanged(
  config: IrohPresenceNudgeConfig,
  events: readonly IrohBindingNudgeEvent[],
): Promise<void> {
  const baseUrl = (config.baseUrl ?? env.CMUX_PRESENCE_NUDGE_URL)?.trim().replace(/\/+$/, "");
  const secret = (config.secret ?? env.CMUX_PRESENCE_NUDGE_SECRET)?.trim();
  if (!baseUrl || !secret || events.length === 0) return;

  const bounded = events.slice(0, IROH_PRESENCE_NUDGE_MAX_EVENTS);
  if (bounded.length < events.length) {
    console.warn("iroh presence nudge events truncated", {
      dropped: events.length - bounded.length,
    });
  }

  let candidateTeams: ReadonlyMap<string, readonly string[]>;
  try {
    candidateTeams = await (config.lookupCandidateTeamIds ?? registryCandidateTeamIds)(bounded);
  } catch {
    // Registry lookup is itself best-effort; the solo-account fallback below
    // still covers teamless users.
    candidateTeams = new Map();
  }

  const doFetch = config.fetchImpl ?? fetch;
  const signal = AbortSignal.timeout(config.timeoutMs ?? IROH_PRESENCE_NUDGE_TIMEOUT_MS);
  const posts: Promise<Response>[] = [];
  for (const event of bounded) {
    const teamIds = new Set([
      ...(candidateTeams.get(irohNudgeEventKey(event)) ?? [])
        .slice(0, IROH_PRESENCE_NUDGE_MAX_TEAMS_PER_EVENT),
      event.userId,
    ]);
    for (const teamId of teamIds) {
      posts.push(doFetch(`${baseUrl}/v1/presence/nudge`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-cmux-nudge-secret": secret,
        },
        body: JSON.stringify({
          deviceId: event.deviceUuid,
          tag: event.tag,
          kind: IROH_PRESENCE_NUDGE_KIND,
          userId: event.userId,
          teamId,
        }),
        signal,
      }));
    }
  }

  const settled = await Promise.allSettled(posts);
  // 404 = no owner pin in that candidate team's DO — expected for every
  // wrong-team candidate and for devices that never heartbeated presence.
  const failed = settled.filter((result) =>
    result.status === "rejected" ||
    (!result.value.ok && result.value.status !== 404)).length;
  if (failed > 0) {
    console.warn("iroh presence nudge delivery incomplete", {
      attempted: settled.length,
      failed,
    });
  }
}

async function registryCandidateTeamIds(
  events: readonly IrohBindingNudgeEvent[],
): Promise<ReadonlyMap<string, readonly string[]>> {
  const deviceUuids = [...new Set(events.map((event) => event.deviceUuid))];
  if (deviceUuids.length === 0) return new Map();
  const rows = await cloudDb()
    .select({
      deviceUuid: devices.deviceUuid,
      userId: devices.userId,
      teamId: devices.teamId,
    })
    .from(devices)
    .where(inArray(devices.deviceUuid, deviceUuids))
    .orderBy(desc(devices.lastSeenAt))
    .limit(CANDIDATE_TEAM_ROW_LIMIT);
  const byEvent = new Map<string, string[]>();
  for (const row of rows) {
    // Registered-by-user must match: another account's registration of the
    // same physical device id must not steer this account's nudges.
    const key = irohNudgeEventKey({ userId: row.userId, deviceUuid: row.deviceUuid });
    const teams = byEvent.get(key) ?? [];
    if (teams.length < IROH_PRESENCE_NUDGE_MAX_TEAMS_PER_EVENT && !teams.includes(row.teamId)) {
      teams.push(row.teamId);
      byEvent.set(key, teams);
    }
  }
  return byEvent;
}
