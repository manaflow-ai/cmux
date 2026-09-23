import { expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

const bundle = ["__CMUX_PROBE__", '{"build_identity":"abc","remote_protocol":12}',
  "__CMUX_DEVICES__", "[]", "__CMUX_TRUSTED__", "1", "__CMUX_END__"].join("\n");

function fixture() {
  const entered = gate(), release = gate();
  const commands: string[] = [], deleted: string[] = [];
  const data = { vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }], resources: { cpu: 64, memory: 131072, storage: 1048576 } };
  const vm = {
    data: async () => data,
    exec: async ({ command }: { command: string }) => {
      commands.push(command);
      return { statusCode: 0, stdout: command.includes("__CMUX_PROBE__") ? bundle : "", stderr: "" };
    },
    fs: { writeTextFile: async () => {}, remove: async () => {} },
    delete: async () => { deleted.push("vm-fixture"); },
  };
  const client = { vms: { create: async () => ({ vm, vmId: "vm-fixture", data }), ref: () => vm } } as unknown as Freestyle;
  const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => { throw new Error("No install expected"); } });
  return { provider, vm, commands, deleted, entered, release };
}

test("VM create overlaps independent reporter setup with CLI upload", async () => {
  const f = fixture();
  f.vm.fs.writeTextFile = async () => { f.entered.release(); await f.release.promise; };
  const creating = f.provider.create({ image: "sh-fixture", network: { id: "vpc-fixture" } });
  await f.entered.promise;
  const overlapped = f.commands.some(command => command.includes("cmux-resource-stats.service"));
  f.release.release();
  await creating;
  expect(overlapped).toBe(true);
  expect(f.deleted).toEqual([]);
});

test("healthy attach overlaps hooks and reporter with the required CLI check", async () => {
  const f = fixture(), exec = f.vm.exec;
  f.vm.exec = async input => {
    const result = await exec(input);
    if (input.command.includes("sha256sum")) { f.entered.release(); await f.release.promise; }
    return result;
  };
  const attaching = f.provider.openCmuxRemote("vm-fixture");
  await f.entered.promise;
  const overlapping = {
    hooks: f.commands.some(command => command.includes("agent hook status")),
    reporter: f.commands.some(command => command.includes("cmux-resource-stats.service")),
  };
  f.release.release();
  const endpoint = await attaching;
  expect(overlapping).toEqual({ hooks: true, reporter: true });
  expect(endpoint.trustedCarrier).toBe(true);
});

test("create failure settles independent setup before destroying the VM", async () => {
  const f = fixture();
  f.vm.fs.writeTextFile = async () => {
    f.entered.release();
    await f.release.promise;
    throw new Error("required CLI upload failed");
  };
  let reporterFinished = false;
  const finishReporter = gate(), exec = f.vm.exec;
  f.vm.exec = async input => {
    if (input.command.includes("cmux-resource-stats.service")) {
      await finishReporter.promise;
      reporterFinished = true;
    }
    return exec(input);
  };
  f.vm.delete = async () => { expect(reporterFinished).toBe(true); f.deleted.push("vm-fixture"); };
  const creating = f.provider.create({ image: "sh-fixture", network: { id: "vpc-fixture" } });
  // Attach the rejection handler before releasing either operation.
  const result = creating.then(() => null, error => error);
  await f.entered.promise;
  f.release.release();
  finishReporter.release();
  expect(await result).toBeInstanceOf(Error);
  expect(f.deleted).toEqual(["vm-fixture"]);
});
