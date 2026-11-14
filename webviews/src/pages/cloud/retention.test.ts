// Automatic cleanup on the Cloud page (retention.ts): the row's date, the one-time notice, the cap
// offer and the archive list read only what the platform put on the records.
import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { sampleMachines } from "./mockData";
import { CloudErrors, type CloudMachine, type CloudSnapshot } from "./ops";
import {
  DAY_MS,
  archives,
  canArchive,
  canKeep,
  capOffer,
  deleteDate,
  noticeKey,
  oldestPaused,
  readDismissed,
  shownNotice,
  writeDismissed,
} from "./retention";

const now = Date.UTC(2026, 10, 9, 12);
const paused = (patch: Partial<CloudMachine> = {}): CloudMachine => ({ ...sampleMachines()[1]!, ...patch });

describe("Cloud cleanup: the row's delete date", () => {
  test("no date without evict_at, for a kept machine, or while a person's archive runs", () => {
    expect(deleteDate(paused(), now)).toBeUndefined();
    expect(deleteDate(paused({ evict_at: null }), now)).toBeUndefined();
    expect(deleteDate(paused({ evict_at: now + 3 * DAY_MS, keep: true }), now)).toBeUndefined();
    expect(deleteDate(paused({ evict_at: now, delete_reason: "requested" }), now)).toBeUndefined();
  });

  test("today, tomorrow, then calendar days in the local time zone", () => {
    expect(deleteDate(paused({ evict_at: now - 1000 }), now)).toEqual({ kind: "today" });
    expect(deleteDate(paused({ evict_at: now + 3_600_000 }), now)).toEqual({ kind: "today" });
    expect(deleteDate(paused({ evict_at: now + DAY_MS }), now)).toEqual({ kind: "tomorrow" });
    expect(deleteDate(paused({ evict_at: now + 2 * DAY_MS }), now)).toEqual({ kind: "days", days: 2 });
    expect(deleteDate(paused({ evict_at: now + 14 * DAY_MS }), now)).toEqual({ kind: "days", days: 14 });
  });
});

describe("Cloud cleanup: Keep and Archive and delete", () => {
  test("Keep shows on a dated unused or never-used machine and on a kept one, never on a failed create", () => {
    expect(canKeep(paused({ evict_at: now, delete_reason: "unused" }))).toBe(true);
    expect(canKeep(paused({ evict_at: now, delete_reason: "never_used" }))).toBe(true);
    expect(canKeep(paused({ evict_at: now, delete_reason: "failed_create" }))).toBe(false);
    expect(canKeep(paused({ keep: true }))).toBe(true);
    expect(canKeep(paused())).toBe(false);
  });

  test("Archive and delete is for a paused machine nobody kept, not already archiving", () => {
    expect(canArchive(paused())).toBe(true);
    expect(canArchive(paused({ keep: true }))).toBe(false);
    expect(canArchive(paused({ delete_reason: "requested", evict_at: now }))).toBe(false);
    expect(canArchive(sampleMachines()[0])).toBe(false);
    expect(canArchive(sampleMachines()[3])).toBe(false);
  });
});

describe("Cloud cleanup: the one-time notice", () => {
  const notice = { kind: "heads_up" as const, at: now - 1000, delete_at: now + 14 * DAY_MS };

  test("shows until dismissed; a new notice (another at) shows again", () => {
    const machine = paused({ evict_at: notice.delete_at, delete_reason: "unused", notice });
    expect(shownNotice(machine, new Set())).toEqual(notice);
    const dismissed = new Set([noticeKey(machine.id, notice.at)]);
    expect(shownNotice(machine, dismissed)).toBeUndefined();
    const last = { kind: "last_note" as const, at: now, delete_at: notice.delete_at };
    expect(shownNotice({ ...machine, notice: last }, dismissed)).toEqual(last);
  });

  test("a kept machine shows none", () => {
    expect(shownNotice(paused({ notice, keep: true }), new Set())).toBeUndefined();
  });

  test("dismissals round-trip through storage and survive a broken or refusing store", () => {
    const store = new Map<string, string>();
    const storage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
    };
    writeDismissed(new Set(["vm_b2:1"]), storage);
    expect([...readDismissed(storage)]).toEqual(["vm_b2:1"]);
    store.set("cmux.cloud.retention.dismissed", "{not json");
    expect(readDismissed(storage).size).toBe(0);
    const refusing = {
      getItem: () => {
        throw new Error("denied");
      },
      setItem: () => {
        throw new Error("full");
      },
    };
    expect(readDismissed(refusing).size).toBe(0);
    expect(() => writeDismissed(new Set(["a"]), refusing)).not.toThrow();
  });
});

describe("Cloud cleanup: the cap offer", () => {
  const machines = [
    sampleMachines()[0]!,
    paused({ id: "vm_new", last_active_at: now - DAY_MS }),
    paused({ id: "vm_old", name: "old", last_active_at: now - 70 * DAY_MS }),
    paused({ id: "vm_kept", name: "kept", last_active_at: now - 99 * DAY_MS, keep: true }),
  ];
  const cap = (details: Record<string, unknown>) =>
    pageError(CloudErrors.quotaExceeded, "this plan allows 4 machines", false, { resource: "machines", ...details });

  test("the platform's free_up is offered as a delete", () => {
    expect(capOffer(cap({ free_up: { machine: "vm_new", name: "scratch", reason: "never_used" } }), machines)).toEqual({
      kind: "delete",
      machine: "vm_new",
      name: "scratch",
    });
  });

  test("without free_up, the oldest paused machine nobody kept is archived", () => {
    expect(capOffer(cap({ free_up: null }), machines)).toEqual({ kind: "archive", machine: "vm_old", name: "old" });
    expect(oldestPaused(machines)?.id).toBe("vm_old");
  });

  test("the provider's words never pick a machine to delete: a name in them only archives", () => {
    const error = pageError(
      "cmux.cloud.upstream_error",
      "Reached the limit of 20 machines (paused ones count). You can delete old (paused 70 days).",
      false,
    );
    expect(capOffer(error, machines)).toEqual({ kind: "archive", machine: "vm_old", name: "old" });
  });

  test("any other refusal, or the active-machines quota, offers nothing", () => {
    expect(
      capOffer(pageError(CloudErrors.quotaExceeded, "3 active", false, { limit: 3, used: 3 }), machines),
    ).toBeUndefined();
    expect(capOffer(new Error("boom"), machines)).toBeUndefined();
    expect(capOffer(cap({}), [sampleMachines()[0]!])).toBeUndefined();
  });
});

describe("Cloud cleanup: archives", () => {
  test("only archive snapshots, newest first, none being deleted", () => {
    const base = { machine: "vm_x", name: null, size_mb: 1, status: "ready" as const, revision: "1" };
    const of = { machine: "vm_x", name: "x", until: now + DAY_MS };
    const list: CloudSnapshot[] = [
      { ...base, id: "s1", created_at: 1 },
      { ...base, id: "s2", created_at: 2, archive_of: of },
      { ...base, id: "s3", created_at: 3, archive_of: of },
      { ...base, id: "s4", created_at: 4, archive_of: of, status: "deleting" },
    ];
    expect(archives(list).map((s) => s.id)).toEqual(["s3", "s2"]);
  });
});

describe("Cloud cleanup: the policy line", () => {
  test("camel-case placeholders are filled", async () => {
    const { format } = await import("./strings");
    expect(format("{days} days, {headsUp} before", { days: 60, headsUp: 14 })).toBe("60 days, 14 before");
  });
});
