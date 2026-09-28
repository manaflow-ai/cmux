import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import {
  creatorFor,
  creatorUserIds,
  readCreatorDisplayNames,
} from "../services/vms/creators";
import { listUserVms } from "../services/vms/workflows";

/**
 * `/api/vm` lists by owner team, so on a team every member sees every member's
 * machines, and until this change the payload carried no author at all. These
 * cases pin the pieces that turn a row's account id into something a person can
 * read in the Cloud sidebar.
 */

function creatorRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-0000000000aa",
    userId: "user-creator",
    billingTeamId: "team-shared",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: "vm-creator",
    displayName: null,
    slug: "brave-blue-otter",
    imageId: "snapshot-test",
    imageVersion: null,
    status: "running",
    idempotencyKey: "creator-metadata",
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ownerTeamId: "team-shared",
    coderouterPoolId: null,
    ...overrides,
  } as CloudVmRow;
}

/** The two calls `readCreatorDisplayNames` makes, and nothing else. */
function fakeSelectDb(rows: readonly { userId: string; displayName: string | null }[]) {
  return {
    select: () => ({
      from: () => ({
        where: () => Promise.resolve([...rows]),
      }),
    }),
  } as unknown as Parameters<typeof readCreatorDisplayNames>[1];
}

function throwingSelectDb() {
  return {
    select: () => {
      throw new Error("identity snapshots unavailable");
    },
  } as unknown as Parameters<typeof readCreatorDisplayNames>[1];
}

describe("cloud machine creator metadata", () => {
  test("creatorUserIds dedupes accounts and drops rows with no author", () => {
    const ids = creatorUserIds([
      { createdByUserId: "user-a" },
      { createdByUserId: "user-b" },
      { createdByUserId: "user-a" },
      { createdByUserId: "  " },
      { createdByUserId: null },
    ]);
    expect(ids.sort()).toEqual(["user-a", "user-b"]);
  });

  test("creatorUserIds returns nothing when no row has an author", () => {
    expect(creatorUserIds([{ createdByUserId: null }])).toEqual([]);
  });

  test("readCreatorDisplayNames maps accounts to names and skips blank ones", async () => {
    const names = await readCreatorDisplayNames(
      ["user-a", "user-b", "user-c"],
      fakeSelectDb([
        { userId: "user-a", displayName: "Ada Lovelace" },
        { userId: "user-b", displayName: "   " },
        { userId: "user-c", displayName: null },
      ]),
    );
    expect(names.get("user-a")).toBe("Ada Lovelace");
    expect(names.has("user-b")).toBe(false);
    expect(names.has("user-c")).toBe(false);
  });

  test("readCreatorDisplayNames does not query for an empty account list", async () => {
    const names = await readCreatorDisplayNames([], throwingSelectDb());
    expect(names.size).toBe(0);
  });

  test("readCreatorDisplayNames degrades to no names when the read fails", async () => {
    // A machine list without authors is what shipped before this, so a broken
    // snapshot read must never take the whole list down with it.
    const names = await readCreatorDisplayNames(["user-a"], throwingSelectDb());
    expect(names.size).toBe(0);
  });

  test("creatorFor publishes the account id with its name", () => {
    const creator = creatorFor(
      { createdByUserId: "user-a" },
      new Map([["user-a", "Ada Lovelace"]]),
    );
    expect(creator).toEqual({ userId: "user-a", displayName: "Ada Lovelace" });
  });

  test("creatorFor reports an unnamed account rather than showing its id as a name", () => {
    const creator = creatorFor({ createdByUserId: "user-a" }, new Map());
    expect(creator).toEqual({ userId: "user-a", displayName: null });
  });

  test("creatorFor returns nothing for a row that predates the author column", () => {
    expect(creatorFor({ createdByUserId: null }, new Map())).toBeNull();
  });

  test("listUserVms carries the account that made each machine", async () => {
    const rows = [
      creatorRow({ providerVmId: "vm-one", userId: "user-a" }),
      creatorRow({
        id: "00000000-0000-4000-8000-0000000000ab",
        providerVmId: "vm-two",
        userId: "user-b",
      }),
    ];
    const repo = {
      listUserVms: () => Effect.succeed(rows),
    } as unknown as VmRepositoryShape;
    const entries = await Effect.runPromise(
      listUserVms("user-a", "team-shared").pipe(
        Effect.provide(Layer.succeed(VmRepository, repo)),
      ),
    );
    expect(entries.map((entry) => entry.createdByUserId)).toEqual([
      "user-a",
      "user-b",
    ]);
  });
});
