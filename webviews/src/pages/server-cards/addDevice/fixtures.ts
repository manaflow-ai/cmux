// l10n-allow-file: gallery and test fixtures, not shipped UI.
// Add Device fixtures: a model in each state, built directly (no host), for the gallery and tests.
// The join token is a fixture.
import {
  AddDeviceModel,
  type AddDeviceServices,
  type AddDeviceState,
  type AvailableComputer,
  type Clock,
  type DeviceListingSummary,
} from "./model";

/** A fixed clock, so the countdown reads the same in every capture. */
export const NOW = Date.UTC(2026, 10, 6, 12, 0, 0);
const fixedClock: Clock = { now: () => NOW, after: () => () => {} };

const inert: AddDeviceServices = {
  list: async () => null,
  addComputer: () => {},
  addByName: () => {},
  enterCode: () => {},
  newCloudMachine: () => {},
  installTailscale: () => {},
  copySetupLine: () => {},
  copyJoinLine: () => {},
  showMachines: () => {},
  signIn: () => {},
  pairAnotherMachine: () => {},
  mint: async () => ({ failure: "failed" }),
  joined: async () => null,
  doctor: async () => [],
};

export const computers: AvailableComputer[] = [
  { name: "studio", address: "studio.tail1234.ts.net", os: "macOS", mine: true, fromSSHConfig: false },
  { name: "build-box", address: "build-box.tail1234.ts.net", os: "linux", mine: false, fromSSHConfig: false },
  { name: "devbox", address: "devbox", os: "", mine: true, fromSSHConfig: true },
  { name: "gpu-west", address: "gpu-west", os: "", mine: true, fromSSHConfig: true },
];

export function listing(available = computers, up = true): DeviceListingSummary {
  return {
    network: {
      kind: up ? "tailscale" : "none",
      up,
      detail: up ? null : "Tailscale is not installed on this computer.",
    },
    available,
  };
}

export const joinLine = {
  line: " curl -fsSL https://cmux.example/v1/machines/join.sh | CMUX_JOIN=cmj_7Q2XK9V4M8RD3TBNW5 sh",
  joinTokenId: "jt_fixture",
  expiresAt: NOW + 581_000,
};

/** A model in `state`; the pair code is offered unless `offer` says otherwise. */
export function fixtureModel(state: Partial<AddDeviceState>): AddDeviceModel {
  return new AddDeviceModel(inert, fixedClock, {
    offer: { join: true, invite: false },
    way: "joinLine",
    candidates: { state: "loaded", listing: listing() },
    ...state,
  });
}

const sshFirst = { offer: { join: false, invite: false } };

export const scenes = {
  idle: () => fixtureModel({}),
  minting: () => fixtureModel({ join: { phase: "minting" } }),
  showing: () => fixtureModel({ join: { phase: "showing", line: joinLine } }),
  copied: () => fixtureModel({ join: { phase: "showing", line: joinLine }, joinCopied: true }),
  lastMinute: () => fixtureModel({ join: { phase: "showing", line: { ...joinLine, expiresAt: NOW + 40_000 } } }),
  joined: () =>
    fixtureModel({
      join: { phase: "joined", line: joinLine, machine: { id: "m_fixture", name: "build-box" } },
      checks: [
        { step: "binary", title: "Install the agent daemon", state: "ok", detail: "" },
        { step: "service", title: "Start it with the machine", state: "ok", detail: "" },
        { step: "heartbeat", title: "Check in with cmux", state: "ok", detail: "" },
        {
          step: "consent",
          title: "Screen sharing and control",
          state: "skip",
          detail: "Screen sharing and control are off",
        },
      ],
    }),
  expired: () => fixtureModel({ join: { phase: "expired" } }),
  signedOut: () => fixtureModel({ join: { phase: "failed", failure: "signedOut" } }),
  unavailable: () => fixtureModel({ join: { phase: "failed", failure: "unavailable" } }),
  invite: () => fixtureModel({ offer: { join: true, invite: true } }),
  advanced: () => fixtureModel({ way: "network" }),
  network: () => fixtureModel({ ...sshFirst, way: "network" }),
  loading: () => fixtureModel({ ...sshFirst, way: "network", candidates: { state: "loading" } }),
  noNetwork: () =>
    fixtureModel({
      ...sshFirst,
      way: "network",
      candidates: { state: "loaded", listing: listing(computers.slice(2), false) },
    }),
  code: () => fixtureModel({ way: "code" }),
  newMac: () => fixtureModel({ way: "newDevice" }),
  setupCopied: () => fixtureModel({ way: "newDevice", copied: true }),
  phone: () => fixtureModel({ way: "newDevice", platform: "phone" }),
} satisfies Record<string, () => AddDeviceModel>;

export type Scene = keyof typeof scenes;
