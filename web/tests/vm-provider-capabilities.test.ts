import { afterEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import { getProvider, vmCapabilitiesFor } from "../services/vms/drivers";
import type { VmProviderCapabilities, VmProviderDriver } from "../services/vms/drivers";
import {
  VmProviderGateway,
  VmProviderGatewayLive,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import { VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";

const expected: VmProviderCapabilities = {
  snapshot: true,
  restore: true,
  fork: false,
  exec: true,
  stats: true,
  ports: true,
  desktop: true,
  sizing: true,
  persistentHome: false,
  attachTransports: ["cmux-remote"],
  ssh: false,
  pause: true,
  getStatus: true,
  revokeEndpointLeases: true,
};

const restoreProperties: Array<() => void> = [];
afterEach(() => {
  for (const restore of restoreProperties.splice(0).reverse()) restore();
});

function replaceDriverProperty(key: keyof VmProviderDriver, value: unknown) {
  const driver = getProvider("freestyle");
  const original = Object.getOwnPropertyDescriptor(driver, key);
  Object.defineProperty(driver, key, { configurable: true, writable: true, value });
  restoreProperties.push(() => {
    if (original) Object.defineProperty(driver, key, original);
    else Reflect.deleteProperty(driver, key);
  });
}

function disable(capability: keyof VmProviderCapabilities) {
  replaceDriverProperty("capabilities", { ...expected, [capability]: false });
}

function runGateway<A>(
  use: (gateway: VmProviderGatewayShape) => Effect.Effect<A, VmProviderOperationError>,
): Promise<A> {
  return Effect.runPromise(
    Effect.flatMap(VmProviderGateway, use).pipe(Effect.provide(VmProviderGatewayLive)),
  );
}

function runGatewayError<A>(
  use: (gateway: VmProviderGatewayShape) => Effect.Effect<A, VmProviderOperationError>,
): Promise<VmProviderOperationError> {
  return Effect.runPromise(
    Effect.flatMap(VmProviderGateway, use).pipe(
      Effect.provide(VmProviderGatewayLive),
      Effect.flip,
    ),
  );
}

describe("declared provider capabilities", () => {
  test("Freestyle declares its current capability matrix", () => {
    expect(getProvider("freestyle").capabilities).toEqual(expected);
  });

  test("optional capabilities match the registered driver's implementations", () => {
    const driver = getProvider("freestyle");
    for (const [flag, method] of [
      ["snapshot", "snapshot"], ["restore", "restore"], ["fork", "fork"],
      ["stats", "getStats"], ["ports", "openPort"], ["ssh", "openSSH"],
      ["getStatus", "getStatus"], ["revokeEndpointLeases", "revokeEndpointLeases"],
    ] as const) {
      expect(typeof driver[method] === "function").toBe(expected[flag]);
    }
  });

  test("gateway exposes the current client capability contract", async () => {
    const caps = await runGateway((gateway) => Effect.sync(() => gateway.capabilities!("freestyle")));
    expect(caps).toEqual(vmCapabilitiesFor("freestyle"));
    expect(caps.attachTransports).toEqual(["cmux-remote"]);
  });
});

describe("gateway branches on declared capabilities before provider calls", () => {
  for (const [flag, method, invoke] of [
    ["snapshot", "snapshot", (g: VmProviderGatewayShape) => g.snapshot!("freestyle", "vm-1")],
    ["restore", "restore", (g: VmProviderGatewayShape) => g.restore!("freestyle", "snap-1")],
    ["fork", "fork", (g: VmProviderGatewayShape) => g.fork!("freestyle", "vm-1")],
    ["stats", "getStats", (g: VmProviderGatewayShape) => g.getStats!("freestyle", "vm-1")],
    ["ports", "openPort", (g: VmProviderGatewayShape) => g.openPort!("freestyle", "vm-1", 3000)],
    ["ssh", "openSSH", (g: VmProviderGatewayShape) => g.openSSH("freestyle", "vm-1")],
  ] as const) {
    test(`${method} refuses a disabled flag even with an implementation`, async () => {
      disable(flag);
      const implementation = mock(async () => { throw new Error("unexpected provider call"); });
      replaceDriverProperty(method, implementation);
      const error = await runGatewayError<unknown>(invoke);
      expect(error).toBeInstanceOf(VmProviderOperationError);
      expect(error.cause).toBeInstanceOf(VmOperationUnsupportedError);
      expect((error.cause as VmOperationUnsupportedError).operation).toBe(method);
      expect(implementation).not.toHaveBeenCalled();
    });
  }

  test("disabled status is assumed running without querying the provider", async () => {
    disable("getStatus");
    const implementation = mock(async () => "paused");
    replaceDriverProperty("getStatus", implementation);
    expect(await runGateway((g) => g.getStatus!("freestyle", "vm-1"))).toBe("running");
    expect(implementation).not.toHaveBeenCalled();
  });

  for (const operation of ["pause", "revokeEndpointLeases"] as const) {
    test(`disabled ${operation} is a no-op`, async () => {
      disable(operation);
      const implementation = mock(async () => undefined);
      replaceDriverProperty(operation, implementation);
      await runGateway((g) => g[operation]!("freestyle", "vm-1"));
      expect(implementation).not.toHaveBeenCalled();
    });
  }

  test("enabled restore preserves the owner's network options", async () => {
    const restored = { provider: "freestyle", providerVmId: "vm-1", status: "running", image: "snap-1", createdAt: 1 } as const;
    const implementation = mock(async () => restored);
    replaceDriverProperty("restore", implementation);
    const options = { network: { id: "owner-network" }, providerMetadata: { source: "restore" } };
    expect(await runGateway((g) => g.restore!("freestyle", "snap-1", options))).toEqual(restored);
    expect(implementation).toHaveBeenCalledWith("snap-1", options);
  });
});
