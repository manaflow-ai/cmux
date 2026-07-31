import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import type {
  IrohRepositoryShape,
  IrohRetentionResult,
  IrohStaleBindingReapResult,
} from "../services/iroh/repository";
import {
  IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT,
  IROH_STALE_RELEASE_BINDING_TTL_HOURS_DEFAULT,
  irohStaleBindingTtlHours,
  runIrohRetention,
} from "../services/iroh/retention";
import type { IrohBindingNudgeEvent } from "../services/iroh/presenceNudge";

const NOW = new Date("2026-07-30T12:00:00.000Z");

const EMPTY_RETENTION: IrohRetentionResult = {
  rowsProcessed: 0,
  batches: 0,
  backlog: false,
  budgetExhausted: null,
  byCategory: {
    revokedHints: 0,
    expiredHints: 0,
    expiredChallenges: 0,
    consumedChallenges: 0,
    relayAudits: 0,
    pairGrantAudits: 0,
    revokedBindings: 0,
  },
};

function stubRepository(reap: IrohStaleBindingReapResult) {
  const calls: Array<{ devCutoff: Date; releaseCutoff: Date; now: Date }> = [];
  const repository = {
    pruneExpiredStateGlobally: () => Effect.succeed(EMPTY_RETENTION),
    reapStaleBindings: (input: { now: Date; devCutoff: Date; releaseCutoff: Date }) => {
      calls.push({ devCutoff: input.devCutoff, releaseCutoff: input.releaseCutoff, now: input.now });
      return Effect.succeed(reap);
    },
  } as unknown as IrohRepositoryShape;
  return { repository, calls };
}

describe("iroh stale-binding TTL configuration", () => {
  test("defaults to 72h for dev tags and 45 days for release channels", () => {
    expect(irohStaleBindingTtlHours({})).toEqual({
      devHours: IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT,
      releaseHours: IROH_STALE_RELEASE_BINDING_TTL_HOURS_DEFAULT,
    });
    expect(IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT).toBe(72);
    expect(IROH_STALE_RELEASE_BINDING_TTL_HOURS_DEFAULT).toBe(45 * 24);
  });

  test("accepts bounded overrides and falls back on garbage", () => {
    expect(irohStaleBindingTtlHours({ dev: "24", release: "2160" })).toEqual({
      devHours: 24,
      releaseHours: 2_160,
    });
    expect(irohStaleBindingTtlHours({ dev: "zero", release: "-4" })).toEqual({
      devHours: IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT,
      releaseHours: IROH_STALE_RELEASE_BINDING_TTL_HOURS_DEFAULT,
    });
    expect(irohStaleBindingTtlHours({ dev: "0" }).devHours)
      .toBe(IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT);
  });
});

describe("iroh retention run", () => {
  test("reaps with shape-specific cutoffs and nudges every reaped binding", async () => {
    const reaped: IrohStaleBindingReapResult = {
      revoked: [
        { userId: "user-a", deviceUuid: "device-1", tag: "wsid", platform: "mac" },
        { userId: "user-b", deviceUuid: "device-2", tag: "default", platform: "ios" },
      ],
      candidates: 2,
      skippedUsers: 0,
      backlog: false,
    };
    const { repository, calls } = stubRepository(reaped);
    const nudged: IrohBindingNudgeEvent[][] = [];

    const summary = await Effect.runPromise(runIrohRetention({
      repository,
      now: NOW,
      ttlHours: { devHours: 72, releaseHours: 1_080 },
      presenceNudge: {
        bindingChanged: (events) => Effect.sync(() => {
          nudged.push([...events]);
        }),
      },
    }));

    expect(calls).toEqual([{
      now: NOW,
      devCutoff: new Date(NOW.getTime() - 72 * 60 * 60 * 1_000),
      releaseCutoff: new Date(NOW.getTime() - 1_080 * 60 * 60 * 1_000),
    }]);
    expect(nudged).toEqual([[
      { userId: "user-a", deviceUuid: "device-1", tag: "wsid" },
      { userId: "user-b", deviceUuid: "device-2", tag: "default" },
    ]]);
    expect(summary.reap).toMatchObject({ revoked: 2, candidates: 2, backlog: false });
  });

  test("does not nudge when nothing was reaped, and a nudge defect cannot fail the run", async () => {
    const quiet = stubRepository({ revoked: [], candidates: 0, skippedUsers: 0, backlog: false });
    let nudges = 0;
    const summaryQuiet = await Effect.runPromise(runIrohRetention({
      repository: quiet.repository,
      now: NOW,
      ttlHours: { devHours: 72, releaseHours: 1_080 },
      presenceNudge: {
        bindingChanged: () => Effect.sync(() => {
          nudges += 1;
        }),
      },
    }));
    expect(nudges).toBe(0);
    expect(summaryQuiet.reap.revoked).toBe(0);

    const reaping = stubRepository({
      revoked: [{ userId: "user-a", deviceUuid: "device-1", tag: "wsid", platform: "mac" }],
      candidates: 1,
      skippedUsers: 0,
      backlog: true,
    });
    const summary = await Effect.runPromise(runIrohRetention({
      repository: reaping.repository,
      now: NOW,
      ttlHours: { devHours: 72, releaseHours: 1_080 },
      presenceNudge: {
        bindingChanged: () => Effect.sync(() => {
          throw new Error("presence worker unreachable");
        }),
      },
    }));
    expect(summary.reap).toMatchObject({ revoked: 1, backlog: true });
  });
});
