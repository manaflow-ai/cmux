import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { getProvider, NotImplementedError } from "../services/vms/drivers";
import type { ProviderId, VmProviderCapabilities } from "../services/vms/drivers";
import {
  VmProviderGateway,
  VmProviderGatewayLive,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import { VmProviderOperationError } from "../services/vms/errors";

// The declared capability matrix IS the provider contract: workflows and routes branch on it
// instead of calling a method and catching NotImplementedError. These assertions pin the
// current truth per provider; flipping a flag is a deliberate feature change, not drift.
const expected: Record<ProviderId, VmProviderCapabilities> = {
  e2b: {
    ssh: false,
    snapshot: true,
    fork: false,
    pause: true,
    getStatus: false,
    getStats: false,
    openPort: false,
    revokeEndpointLeases: false,
  },
  daytona: {
    ssh: false,
    snapshot: true,
    fork: false,
    pause: true,
    getStatus: true,
    getStats: false,
    openPort: false,
    revokeEndpointLeases: false,
  },
  freestyle: {
    ssh: true,
    snapshot: true,
    fork: true,
    pause: true,
    getStatus: true,
    getStats: false,
    openPort: false,
    revokeEndpointLeases: false,
  },
  blaxel: {
    ssh: false,
    snapshot: false,
    fork: false,
    pause: false,
    getStatus: true,
    getStats: true,
    openPort: true,
    revokeEndpointLeases: true,
  },
};

describe("declared provider capabilities", () => {
  for (const [provider, caps] of Object.entries(expected) as Array<[ProviderId, VmProviderCapabilities]>) {
    test(`${provider} declares its capability matrix`, () => {
      expect(getProvider(provider).capabilities).toEqual(caps);
    });
  }

  test("a declared capability is backed by an implementation, and vice versa for optional methods", () => {
    for (const provider of Object.keys(expected) as ProviderId[]) {
      const driver = getProvider(provider);
      // Optional interface methods must exist exactly when the flag is true.
      expect(!!driver.snapshot).toBe(driver.capabilities.snapshot);
      expect(!!driver.restore).toBe(driver.capabilities.snapshot);
      expect(!!driver.fork).toBe(driver.capabilities.fork);
      expect(!!driver.getStats).toBe(driver.capabilities.getStats);
      expect(!!driver.openPort).toBe(driver.capabilities.openPort);
      expect(!!driver.getStatus).toBe(driver.capabilities.getStatus);
      expect(!!driver.revokeEndpointLeases).toBe(driver.capabilities.revokeEndpointLeases);
    }
  });
});

function runGateway<A>(
  use: (gateway: VmProviderGatewayShape) => Effect.Effect<A, VmProviderOperationError>,
): Promise<A> {
  return Effect.runPromise(
    Effect.flatMap(VmProviderGateway, use).pipe(Effect.provide(VmProviderGatewayLive)) as Effect.Effect<
      A,
      VmProviderOperationError,
      never
    >,
  );
}

/** Runs a gateway effect expected to fail and resolves with its typed VmProviderOperationError. */
function runGatewayError<A>(
  use: (gateway: VmProviderGatewayShape) => Effect.Effect<A, VmProviderOperationError>,
): Promise<VmProviderOperationError> {
  return Effect.runPromise(
    Effect.flatMap(VmProviderGateway, use).pipe(
      Effect.provide(VmProviderGatewayLive),
      Effect.flip,
    ) as Effect.Effect<VmProviderOperationError, never, never>,
  );
}

// Gateway gating happens BEFORE any provider round-trip, so all of these run offline against
// the real drivers: an unsupported operation must fail from the declared flag alone.
describe("gateway branches on declared capabilities", () => {
  test("exposes the capability matrix per provider", async () => {
    const caps = await runGateway((gateway) => Effect.sync(() => gateway.capabilities!("blaxel")));
    expect(caps).toEqual(expected.blaxel);
  });

  test("snapshot on a provider without snapshots is NotImplementedError, without a provider call", async () => {
    const err = await runGatewayError((gateway) => gateway.snapshot!("blaxel", "machine-a"));
    expect(err).toBeInstanceOf(VmProviderOperationError);
    expect(err.cause).toBeInstanceOf(NotImplementedError);
    expect((err.cause as Error).message).toBe("[blaxel] snapshot: not implemented yet");
  });

  test("restore mirrors the snapshot gate", async () => {
    const err = await runGatewayError((gateway) => gateway.restore!("blaxel", "snap-1"));
    expect(err.cause).toBeInstanceOf(NotImplementedError);
    expect((err.cause as Error).message).toBe("[blaxel] restore: not implemented yet");
  });

  test("fork on a provider without forks keeps the historical error message", async () => {
    const err = await runGatewayError((gateway) => gateway.fork!("e2b", "sbx-1"));
    expect((err.cause as Error).message).toBe("Cloud VM forks are not supported by this provider");
  });

  test("getStats and openPort gates keep their historical messages", async () => {
    const statsErr = await runGatewayError((gateway) => gateway.getStats!("e2b", "sbx-1"));
    expect((statsErr.cause as Error).message).toBe("provider e2b does not report machine stats");
    const portErr = await runGatewayError((gateway) => gateway.openPort!("freestyle", "vm-1", 3000));
    expect((portErr.cause as Error).message).toBe("provider freestyle does not support opening ports");
  });

  test("a provider without getStatus is assumed running", async () => {
    expect(await runGateway((gateway) => gateway.getStatus!("e2b", "sbx-1"))).toBe("running");
  });

  test("revokeEndpointLeases is a no-op for providers without revocable ingress", async () => {
    await expect(runGateway((gateway) => gateway.revokeEndpointLeases!("e2b", "sbx-1"))).resolves.toBeUndefined();
  });
});
