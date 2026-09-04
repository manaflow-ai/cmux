import { describe, expect, test } from "bun:test";

import { getProvider, vmCapabilitiesFor, vmCapabilitiesOf } from "../services/vms/drivers";
import { MockVMProvider } from "../services/vms/drivers/mock";

// Capabilities are the client-visible provider contract: every VM API response
// carries them, and the CLI gates verbs on them instead of assuming a provider
// name. Derivation must follow method presence (structural) unless the driver
// declares otherwise, and capabilities with no structural signal must default
// to false so a driver has to opt in to what it actually honors.
describe("vm capability derivation", () => {
  test("freestyle: derived from the real driver, not hardcoded", () => {
    const caps = vmCapabilitiesFor("freestyle");
    expect(caps).toEqual({
      snapshot: true,
      restore: true,
      fork: false,
      exec: true,
      stats: false,
      // Port previews ride the platform's TLS edge (style.dev capability URLs).
      ports: true,
      desktop: false,
      // Grow-only live resize honors memoryMb as a floor.
      sizing: true,
      persistentHome: false,
      attachTransports: ["cmux-remote"],
    });
  });

  test("freestyle driver no longer carries throwing attach/ssh stubs", () => {
    const driver = getProvider("freestyle");
    expect(driver.openAttach).toBeUndefined();
    expect(driver.openSSH).toBeUndefined();
    expect(driver.revokeSSHIdentity).toBeUndefined();
  });

  test("a minimal provider derives the minimal capability set", () => {
    const caps = vmCapabilitiesOf(new MockVMProvider({ features: { cmuxRemote: false } }));
    expect(caps.fork).toBe(false);
    expect(caps.stats).toBe(false);
    expect(caps.ports).toBe(false);
    expect(caps.desktop).toBe(false);
    expect(caps.sizing).toBe(false);
    expect(caps.persistentHome).toBe(false);
    expect(caps.attachTransports).toEqual([]);
  });

  test("a fully-featured provider derives everything structurally", () => {
    const caps = vmCapabilitiesOf(
      new MockVMProvider({
        features: { fork: true, stats: true, ports: true, ssh: true, websocket: true },
      }),
    );
    expect(caps.fork).toBe(true);
    expect(caps.stats).toBe(true);
    expect(caps.ports).toBe(true);
    expect(caps.attachTransports).toEqual(["cmux-remote", "websocket", "ssh"]);
  });

  test("declared capabilities override structural facts", () => {
    // A driver that implements snapshot only to throw declares snapshot: false;
    // one that honors sizing at create time declares sizing: true.
    const caps = vmCapabilitiesOf(
      new MockVMProvider({
        features: { fork: true },
        capabilities: { snapshot: false, sizing: true, desktop: true, fork: false },
      }),
    );
    expect(caps.snapshot).toBe(false);
    expect(caps.sizing).toBe(true);
    expect(caps.desktop).toBe(true);
    expect(caps.fork).toBe(false);
  });

  test("the mock provider honors the driver contract end to end", async () => {
    const mock = new MockVMProvider({ features: { fork: true } });
    const vm = await mock.create({ image: "mock-image" });
    expect(vm.status).toBe("running");
    const snap = await mock.snapshot(vm.providerVmId, "before");
    const restored = await mock.restore(snap.id);
    expect(restored.image).toBe("mock-image");
    const forked = await mock.fork!(vm.providerVmId);
    expect(forked.providerVmId).not.toBe(vm.providerVmId);
    await mock.pause(vm.providerVmId);
    expect(await mock.getStatus(vm.providerVmId)).toBe("paused");
    mock.scriptExec(vm.providerVmId, (command) => ({ exitCode: 7, stdout: command, stderr: "" }));
    const result = await mock.exec(vm.providerVmId, "uname -a");
    expect(result).toEqual({ exitCode: 7, stdout: "uname -a", stderr: "" });
    await mock.destroy(vm.providerVmId);
    expect(await mock.getStatus(vm.providerVmId)).toBe("destroyed");
  });
});
