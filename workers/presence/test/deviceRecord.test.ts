import { describe, expect, it } from "bun:test";
import type { DeviceInstanceRecord, DeviceRecord } from "../src/syncDevices";

// Cross-language device-record contract. These are the SAME golden fixtures the
// Swift suite loads (Packages/Shared/CmuxSyncStore/Tests/.../SyncFrameAndProtocolTests.swift,
// DeviceRecordFixtureContractTests). A field rename/retype/removal on either
// side makes that side diverge from _expected.json and goes red. Plus, two
// type-level guards below fail `bun run typecheck` (tsc): `asDeviceRecord`
// catches a field RENAME (the reconstruction's property read goes missing), and
// `_pinWireTypes` catches a field RETYPE (the value no longer assigns to the
// pinned local type). Additive-only: add a field + add/extend a fixture. Per the
// substrate (workers/presence/src/sync.ts) additive payload fields do NOT bump
// SYNC_SCHEMA_VERSION; the additive-only lint is the compat guarantee.
// See plans/feat-ios-device-list-v2/PLAN.md Stage 1.

const FIX_DIR = `${import.meta.dir}/../../../Packages/Shared/CmuxSyncStore/Fixtures/devices`;
const load = (name: string): Promise<unknown> => Bun.file(`${FIX_DIR}/${name}`).json();

/** Names every wire field explicitly, so a RENAME in the DeviceRecord /
 * DeviceInstanceRecord interfaces is a compile error here (excess + missing
 * property), not a silent runtime divergence. (RETYPES flow through `any`
 * unchanged here; `_pinWireTypes` below covers those.) */
function asDeviceRecord(raw: any): DeviceRecord {
  return {
    deviceId: raw.deviceId,
    platform: raw.platform,
    displayName: raw.displayName,
    ownerUserId: raw.ownerUserId,
    lastSeenAtAtRev: raw.lastSeenAtAtRev,
    instances: (raw.instances ?? []).map(
      (i: any): DeviceInstanceRecord => ({
        tag: i.tag,
        routes: i.routes,
        lastSeenAtAtRev: i.lastSeenAtAtRev,
      }),
    ),
  };
}

/** Compile-time wire-type pins. A field RETYPE (e.g. `lastSeenAtAtRev: number`
 * -> `string`) makes the value no longer assignable to the pinned local type, a
 * tsc error; a RENAME makes the property read missing. Never executed; it exists
 * solely so `bun run typecheck` enforces the scalar wire types, closing the gap
 * that `asDeviceRecord`'s `any` path leaves open. */
function _pinWireTypes(r: DeviceRecord, i: DeviceInstanceRecord): void {
  const deviceId: string = r.deviceId;
  const platform: string = r.platform;
  const displayName: string | undefined = r.displayName;
  const ownerUserId: string | undefined = r.ownerUserId;
  const recordLastSeen: number = r.lastSeenAtAtRev;
  const instances: DeviceInstanceRecord[] = r.instances;
  const tag: string = i.tag;
  const instanceLastSeen: number = i.lastSeenAtAtRev;
  const routes: readonly unknown[] = i.routes;
  // Optionality pins: `undefined` must remain assignable to these fields. If a
  // future change drops the `?` (optional -> required, a compat break since
  // production deriveDeviceRecord omits both for unnamed/unowned devices), then
  // `undefined` no longer assigns and this fails typecheck.
  const optDisplayName: DeviceRecord["displayName"] = undefined;
  const optOwnerUserId: DeviceRecord["ownerUserId"] = undefined;
  void [deviceId, platform, displayName, ownerUserId, recordLastSeen, instances, tag,
    instanceLastSeen, routes, optDisplayName, optOwnerUserId];
}

// Exhaustive key maps. `Record<keyof X, true>` forces EVERY interface key to be
// listed, so adding a field to DeviceRecord / DeviceInstanceRecord without listing
// it here fails `bun run typecheck`. The "source types match the lock" test then
// ties these keys to the checked-in field lock, so a new field must also land in
// the lock (and a fixture). This closes the source-type -> lock drift path the
// fixture coverage alone cannot see (an optional field is source-compatible).
const DEVICE_RECORD_KEYS: Record<keyof DeviceRecord, true> = {
  deviceId: true,
  platform: true,
  displayName: true,
  ownerUserId: true,
  lastSeenAtAtRev: true,
  instances: true,
};
const DEVICE_INSTANCE_KEYS: Record<keyof DeviceInstanceRecord, true> = {
  tag: true,
  routes: true,
  lastSeenAtAtRev: true,
};

describe("device-record cross-language contract", () => {
  it("every fixture matches the shared expectations", async () => {
    const expected = (await load("_expected.json")) as Record<string, any>;
    let checked = 0;

    // Known route kinds across the whole contract (the consumer-visible kinds).
    // Used to pin the route `kind` discriminator at runtime while exempting
    // deliberately-unknown future kinds, exactly as the Swift CmxAttachRoute
    // decoder drops them.
    const knownKinds = new Set<string>();
    for (const [n, e] of Object.entries(expected)) {
      if (n.startsWith("_")) continue;
      for (const ei of (e as any).instances ?? []) for (const k of ei.routeKinds ?? []) knownKinds.add(k);
    }

    for (const [name, exp] of Object.entries(expected)) {
      if (name.startsWith("_")) continue;
      const fixture = (await load(name)) as any;

      if (exp.decodes === false) {
        // Tombstone / non-record payload: carries no device identity.
        expect(fixture.deviceId, `${name}: tombstone must not be a device record`).toBeUndefined();
        checked++;
        continue;
      }

      const record = asDeviceRecord(fixture);
      if (exp.deviceId !== undefined) expect(record.deviceId, `${name} deviceId`).toBe(exp.deviceId);
      if (exp.platform !== undefined) expect(record.platform, `${name} platform`).toBe(exp.platform);
      if (exp.displayName !== undefined) expect(record.displayName, `${name} displayName`).toBe(exp.displayName);
      if (exp.ownerUserId !== undefined) expect(record.ownerUserId, `${name} ownerUserId`).toBe(exp.ownerUserId);
      if (exp.lastSeenAtAtRev !== undefined)
        expect(record.lastSeenAtAtRev, `${name} lastSeenAtAtRev`).toBe(exp.lastSeenAtAtRev);
      if (exp.instanceCount !== undefined)
        expect(record.instances.length, `${name} instanceCount`).toBe(exp.instanceCount);

      const insts = exp.instances as Array<any> | undefined;
      if (insts) {
        expect(record.instances.length, `${name} instances length`).toBe(insts.length);
        insts.forEach((ei, i) => {
          const inst = record.instances[i]!;
          if (ei.tag !== undefined) expect(inst.tag, `${name} instance[${i}] tag`).toBe(ei.tag);
          expect(Array.isArray(inst.routes), `${name} instance[${i}] routes is array`).toBe(true);
          // Pin the route `kind` discriminator at runtime: the raw wire kinds,
          // filtered to known kinds (dropping deliberate unknowns like the
          // future-route probe, exactly as Swift's CmxAttachRoute decoder does),
          // must equal the consumer-visible routeKinds. Catches a `kind`
          // rename/retype in the wire on the TS side. The FULL route schema is
          // owned by Swift's CmxAttachRoute (the Swift suite decodes it strictly);
          // the worker treats routes as an opaque passthrough, so there is no TS
          // route type to pin at compile time here.
          if (Array.isArray(ei.routeKinds)) {
            const rawKinds: string[] = (fixture.instances?.[i]?.routes ?? []).map((r: any) => r?.kind);
            const knownRawKinds = rawKinds.filter((k) => knownKinds.has(k));
            expect(knownRawKinds, `${name} instance[${i}] route kinds`).toEqual(ei.routeKinds);
          }
        });
      }
      checked++;
    }

    expect(checked, "fixtures checked").toBeGreaterThanOrEqual(5);
  });

  it("source record types match the checked-in field lock", async () => {
    const lock = (await load("device-record.fields.json")) as any;
    const lockKeys = (t: string): string[] => Object.keys(lock.types?.[t] ?? {}).sort();
    // DEVICE_*_KEYS is exhaustive over the interface (tsc-enforced above), so this
    // ties the TS source types to the lock: a field added to either record type
    // must also be added to device-record.fields.json (and a fixture).
    expect(Object.keys(DEVICE_RECORD_KEYS).sort(), "DeviceRecord source vs lock").toEqual(
      lockKeys("DeviceRecord"),
    );
    expect(Object.keys(DEVICE_INSTANCE_KEYS).sort(), "DeviceInstanceRecord source vs lock").toEqual(
      lockKeys("DeviceInstanceRecord"),
    );
  });
});
