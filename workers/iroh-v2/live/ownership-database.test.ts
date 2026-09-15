import { expect, test } from "bun:test";
import postgres from "postgres";
import { DeviceDescriptorSchema } from "../src/contracts/common";
import { OperationError } from "../src/errors";
import { PlanetScaleOwnership } from "../src/ownership/planetscale";

// Opt-in deployed-database regression. Reuses an existing reservation, so it
// exercises the real connection pool and transaction without creating a device.
const databaseURL = process.env.IROH_V2_OWNERSHIP_SMOKE_DATABASE_URL;
test.skipIf(!databaseURL)("shared database accepts ownership retries and preserves the original owner", async () => {
  const connection = postgres(databaseURL!, {
    max: 1, prepare: false, connect_timeout: 5, ssl: { rejectUnauthorized: true },
  });
  try {
    const [existing] = await connection`SELECT endpoint_id, identity_json, identity_hash FROM iroh_v2_endpoint_owners ORDER BY endpoint_id LIMIT 1`;
    if (!existing) throw new Error("Ownership smoke requires an existing reservation");
    const device = DeviceDescriptorSchema.parse({
      endpointId: existing.endpoint_id,
      identity: JSON.parse(existing.identity_json),
      identityGeneration: 0,
      metadata: {
        platform: "ios", displayName: "Existing reservation smoke", appVersion: "test",
        pairingEnabled: false, capabilities: [], relayURLs: [],
      },
    });
    const ownership = new PlanetScaleOwnership(databaseURL!, device.identity.environment, device.identity.projectId);
    await ownership.reserve(device, Math.floor(Date.now() / 1000));
    await ownership.reserve(device, Math.floor(Date.now() / 1000));
    const conflicting = { ...device, identity: { ...device.identity, deviceId: crypto.randomUUID() } };
    await expect(ownership.reserve(conflicting, Math.floor(Date.now() / 1000)))
      .rejects.toMatchObject(new OperationError("endpoint_already_owned", 409));
    const rows = await connection`SELECT identity_hash, identity_json FROM iroh_v2_endpoint_owners WHERE endpoint_id = ${device.endpointId}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.identity_hash).toBe(existing.identity_hash);
    expect(rows[0]!.identity_json).toBe(existing.identity_json);
  } finally { await connection.end({ timeout: 1 }); }
}, 30_000);
