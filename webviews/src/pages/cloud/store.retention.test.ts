// Automatic cleanup through the store: Keep, Archive and delete (native), the notice dismissal, the
// cap offer's make-room create, and the cleanup settings.
import { describe, expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudOps, type CloudMachine, type CloudRetention } from "./ops";
import { CloudStore, confirmedValue } from "./store";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const DAY = 86_400_000;

const retention = (): CloudRetention => ({
  mode: "on",
  settings: {
    tier: "retained",
    failed_create_hours: 1,
    never_used_hours: 24,
    idle_pause_minutes: 30,
    worked_in_days: 60,
    heads_up_days: 14,
    last_note_days: 1,
    archive_days: 90,
  },
  team: {},
  email_heads_up: true,
});

async function started(provider: MockCloudProvider) {
  let key = 0;
  const store = new CloudStore(provider, { newKey: () => `key_${++key}` });
  const unsubscribe = store.subscribe(() => undefined);
  for (let i = 0; i < 4; i++) await flush();
  return { store, provider, unsubscribe };
}

function provider(): MockCloudProvider {
  const p = new MockCloudProvider({ unsupported: [] });
  p.retention = retention();
  const b2 = p.machines.find((m) => m.id === "vm_b2")!;
  Object.assign(b2, {
    evict_at: Date.now() + 14 * DAY,
    delete_reason: "unused",
    notice: { kind: "heads_up", at: 1, delete_at: Date.now() + 14 * DAY },
  } satisfies Partial<CloudMachine>);
  return p;
}

const machine = (store: CloudStore, id: string) => store.getSnapshot().machines.find((m) => m.id === id);
const actions = (p: MockCloudProvider, action: string) =>
  p.calls.filter((c) => c.op === ACTION_RUN && (c.params as { action?: string }).action === action);

describe("Cloud cleanup: Keep", () => {
  test("Keep pins the machine: no date, no notice; unkeep dates it again", async () => {
    const { store, provider: p, unsubscribe } = await started(provider());
    await store.keep("vm_b2", true);
    await flush();
    expect(p.calls.some((c) => c.op === CloudOps.machineKeep)).toBe(true);
    expect(machine(store, "vm_b2")).toMatchObject({ keep: true, evict_at: null, notice: null });
    await store.keep("vm_b2", false);
    await flush();
    expect(machine(store, "vm_b2")).toMatchObject({ keep: false, delete_reason: "unused" });
    expect(typeof machine(store, "vm_b2")!.evict_at).toBe("number");
    unsubscribe();
  });
});

describe("Cloud cleanup: Archive and delete", () => {
  test("a native action; the machine goes and its archive is listed", async () => {
    const { store, provider: p, unsubscribe } = await started(provider());
    await store.archiveDelete("vm_b2");
    for (let i = 0; i < 4; i++) await flush();
    expect(actions(p, CloudOps.machineArchiveDelete)).toHaveLength(1);
    expect(p.calls.some((c) => c.op === CloudOps.machineArchiveDelete)).toBe(false);
    expect(machine(store, "vm_b2")).toBeUndefined();
    const [archive] = store.getSnapshot().archives;
    expect(archive?.archive_of).toMatchObject({ machine: "vm_b2", name: "build-cache" });
    unsubscribe();
  });

  test("declined at the confirmation: nothing changes", async () => {
    const p = provider();
    p.confirm = false;
    const { store, unsubscribe } = await started(p);
    await store.archiveDelete("vm_b2");
    await flush();
    expect(machine(store, "vm_b2")).toBeDefined();
    expect(store.getSnapshot().archives).toEqual([]);
    unsubscribe();
  });
});

describe("Cloud cleanup: the notice", () => {
  test("Dismiss hides it for that machine and notice", async () => {
    const { store, unsubscribe } = await started(provider());
    expect(store.getSnapshot().dismissed.has("vm_b2:1")).toBe(false);
    store.dismissNotice("vm_b2", 1);
    expect(store.getSnapshot().dismissed.has("vm_b2:1")).toBe(true);
    unsubscribe();
  });
});

describe("Cloud cleanup: the cap offer", () => {
  async function atCap(p: MockCloudProvider) {
    p.machinesCap = p.machines.length;
    const ctx = await started(p);
    ctx.store.openCreate();
    await flush();
    ctx.store.updateDraft({ memoryMb: 4096 });
    await ctx.store.submitCreate();
    await flush();
    return ctx;
  }

  test("the platform's free_up: delete it, then the create runs", async () => {
    const p = provider();
    p.freeUp = { machine: "vm_c3", name: null, reason: "failed_create" };
    const { store, unsubscribe } = await atCap(p);
    expect(store.getSnapshot().create?.offer).toEqual({ kind: "delete", machine: "vm_c3", name: "vm_c3" });
    expect(store.getSnapshot().error).toBeUndefined();
    await store.makeRoom();
    for (let i = 0; i < 4; i++) await flush();
    expect(actions(p, CloudOps.machineDelete)).toHaveLength(1);
    expect(actions(p, CloudOps.machineCreate)).toHaveLength(2);
    // The refused key replays its refusal: the create after making room sends a new one.
    const keys = actions(p, CloudOps.machineCreate).map(
      (call) => (call.params as { args: { idempotency_key: string } }).args.idempotency_key,
    );
    expect(new Set(keys).size).toBe(2);
    expect(machine(store, "vm_c3")).toBeUndefined();
    expect(store.getSnapshot().create).toBeUndefined();
    unsubscribe();
  });

  test("nothing to free but a paused machine: archive it, wait for its removal, then create", async () => {
    const p = provider();
    p.archiveAtOnce = false;
    const { store, unsubscribe } = await atCap(p);
    expect(store.getSnapshot().create?.offer).toMatchObject({ kind: "archive", machine: "vm_b2" });
    await store.makeRoom();
    await flush();
    expect(store.getSnapshot().create?.waitingFor).toBe("vm_b2");
    expect(store.getSnapshot().create?.submitting).toBe(false);
    expect(actions(p, CloudOps.machineCreate)).toHaveLength(1);
    p.finishArchives();
    for (let i = 0; i < 4; i++) await flush();
    expect(actions(p, CloudOps.machineCreate)).toHaveLength(2);
    expect(store.getSnapshot().create).toBeUndefined();
    unsubscribe();
  });
});

test("Cancel while the archive runs closes the sheet; the removal then creates nothing", async () => {
  const p = provider();
  p.archiveAtOnce = false;
  p.machinesCap = p.machines.length;
  const { store, unsubscribe } = await started(p);
  store.openCreate();
  await flush();
  store.updateDraft({ memoryMb: 4096 });
  await store.submitCreate();
  await store.makeRoom();
  await flush();
  store.closeCreate();
  expect(store.getSnapshot().create).toBeUndefined();
  p.finishArchives();
  for (let i = 0; i < 4; i++) await flush();
  expect(actions(p, CloudOps.machineCreate)).toHaveLength(1);
  unsubscribe();
});

describe("Cloud cleanup: settings", () => {
  test("the email heads-up toggle saves and the plan reads it back", async () => {
    const { store, provider: p, unsubscribe } = await started(provider());
    expect(store.getSnapshot().plan?.retention?.email_heads_up).toBe(true);
    await store.setEmailHeadsUp(false);
    await flush();
    expect(p.retention!.email_heads_up).toBe(false);
    expect(store.getSnapshot().plan?.retention?.email_heads_up).toBe(false);
    unsubscribe();
  });

  test("a non-admin's team numbers are refused as admin-only, not a page error", async () => {
    const p = provider();
    p.retentionForbidden = true;
    const { store, unsubscribe } = await started(p);
    await store.setTeamRetention({ heads_up_days: 7 });
    expect(store.getSnapshot().retention).toEqual({ saving: false, forbidden: true });
    expect(store.getSnapshot().error).toBeUndefined();
    unsubscribe();
  });

  test("an admin's numbers save; Reset clears them", async () => {
    const { store, provider: p, unsubscribe } = await started(provider());
    await store.setTeamRetention({ heads_up_days: 7 });
    await flush();
    expect(store.getSnapshot().plan?.retention?.team).toEqual({ heads_up_days: 7 });
    await store.setTeamRetention(null);
    await flush();
    expect(p.retention!.team).toEqual({});
    unsubscribe();
  });
});

describe("Cloud cleanup: native answers", () => {
  test("a confirmed op's answer under `value` is unwrapped; a flat or declined answer stays as it is", () => {
    const machine = { id: "vm_n1" } as CloudMachine;
    expect(confirmedValue({ confirmed: true, value: { machine, revision: 7 } })).toEqual({
      confirmed: true,
      machine,
      revision: 7,
    });
    expect(confirmedValue({ confirmed: true, machine, revision: 7 })).toEqual({
      confirmed: true,
      machine,
      revision: 7,
    });
    expect(confirmedValue({ confirmed: false })).toEqual({ confirmed: false });
    expect(confirmedValue(null)).toBeNull();
  });

  test("Restore (a confirmed op, answered under `value`): the new machine shows and no Creating… row stays", async () => {
    const { store, provider: p, unsubscribe } = await started(provider());
    await store.archiveDelete("vm_b2");
    for (let i = 0; i < 4; i++) await flush();
    const [archive] = store.getSnapshot().archives;
    expect(archive).toBeDefined();
    await store.restoreArchive({ ...archive!, status: "ready" });
    for (let i = 0; i < 4; i++) await flush();
    expect(actions(p, CloudOps.snapshotRestore)).toHaveLength(1);
    const restored = store.getSnapshot().machines.filter((m) => m.name === "build-cache");
    expect(restored).toHaveLength(1);
    expect(store.getSnapshot().pending.filter((intent) => intent.kind === "create")).toEqual([]);
    expect(store.getSnapshot().rows.filter((row) => row.pending === "create")).toEqual([]);
    unsubscribe();
  });
});

test("Return during the make-room archive wait sends no create; the removal then creates once", async () => {
  const p = provider();
  p.archiveAtOnce = false;
  p.machinesCap = p.machines.length;
  const { store, unsubscribe } = await started(p);
  store.openCreate();
  await flush();
  store.updateDraft({ memoryMb: 4096 });
  await store.submitCreate();
  await store.makeRoom();
  await flush();
  expect(store.getSnapshot().create?.waitingFor).toBe("vm_b2");
  // What Return in the name field calls (CreateSheet onKeyDown).
  await store.submitCreate();
  await flush();
  expect(actions(p, CloudOps.machineCreate)).toHaveLength(1);
  expect(store.getSnapshot().create?.waitingFor).toBe("vm_b2");
  p.finishArchives();
  for (let i = 0; i < 4; i++) await flush();
  expect(actions(p, CloudOps.machineCreate)).toHaveLength(2);
  expect(store.getSnapshot().create).toBeUndefined();
  unsubscribe();
});
