import type { MeshDeviceRow } from "../db/mesh.ts";
import { projectVmPeers } from "./vm-policy.ts";
import type { DesiredRule } from "./acl.ts";

/** The reverse of device VM service grants, excluding every ambiguous identity. */
export const projectVmReceivers = (vmId: string, devices: ReadonlyArray<Pick<MeshDeviceRow, "deviceId" | "wgPublicKey" | "installPublicKey">>, rules: ReadonlyArray<DesiredRule>) => {
  const counts = (values: ReadonlyArray<string | null>) => {
    const found = new Map<string | null, number>();
    for (const value of values) found.set(value, (found.get(value) ?? 0) + 1);
    return found;
  };
  const ids = counts(devices.map((d) => d.deviceId)), keys = counts(devices.map((d) => d.wgPublicKey)), points = counts(devices.map((d) => d.installPublicKey));
  return devices.flatMap((device) => {
    if (device.installPublicKey === null || ids.get(device.deviceId) !== 1 || keys.get(device.wgPublicKey) !== 1 || points.get(device.installPublicKey) !== 1) return [];
    const vm = projectVmPeers(device.deviceId, [{ vmId, ipv4: null }], rules)[0];
    return vm === undefined ? [] : [{ deviceId: device.deviceId, wgPublicKey: device.wgPublicKey, installPublicKey: device.installPublicKey, allow: vm.allow }];
  }).sort((a, b) => a.deviceId < b.deviceId ? -1 : a.deviceId > b.deviceId ? 1 : 0);
};
