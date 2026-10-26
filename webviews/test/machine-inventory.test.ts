import { expect, test } from "bun:test";
import { cloudEnvironments } from "../src/agent-session/acpmux/machineInventory";

test("Cloud inventory is unknown before the current-account store loads", () => {
  expect(cloudEnvironments({ loaded: false, machines: [{ id: "stale", name: "Old team", state: "running" }] })).toEqual(
    [],
  );
});

test("Cloud state and registry ids reach the picker without peer-name guesses", () => {
  expect(
    cloudEnvironments({
      loaded: true,
      signedIn: true,
      machines: [
        { id: "vm-paused", name: "Cloud machine", state: "paused", connected: false },
        { id: "vm-run", name: "GCP box", state: "running", connected: true },
        { id: "vm-making", name: "New VM", state: "provisioning", connected: false },
        { id: "vm-old", name: "Deleted", state: "destroyed", connected: false },
      ],
    }),
  ).toEqual([
    { id: "vm-paused", label: "Cloud machine", kind: "cloud", native: true, status: "paused", connected: false },
    { id: "vm-run", label: "GCP box", kind: "cloud", native: true, status: "connected", connected: true },
    { id: "vm-making", label: "New VM", kind: "cloud", native: true, status: "connecting", connected: false },
  ]);
});

test("signed out inventory is never actionable even if an old store says loaded", () => {
  expect(
    cloudEnvironments({
      loaded: true,
      signedIn: false,
      machines: [{ id: "old", name: "Old account", state: "paused" }],
    }),
  ).toEqual([]);
});
