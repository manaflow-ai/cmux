import type { DeviceDescriptor } from "../src/contracts/common";

export const descriptor: DeviceDescriptor = {
  identity: { environment: "staging", projectId: "project", teamId: "team", userId: "user", deviceId: "device", appNamespace: "com.cmux.app.internal", buildTag: "iv2g" },
  endpointId: "ab".repeat(32), identityGeneration: 1,
  metadata: { platform: "mac", displayName: "Test Mac", appVersion: "1", pairingEnabled: true, capabilities: ["terminal"], relayURLs: ["https://relay.example/"] },
};
