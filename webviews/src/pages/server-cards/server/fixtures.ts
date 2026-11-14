// l10n-allow-file: gallery and test fixtures (canned servers), not shipped UI.
// Canned servers for the gallery, the browser dev loop and tests: a paired Mac mini, a MacBook on
// battery with low disk, a fresh Mac showing its pairing code, a paired Linux box without a display.
// `status` builds the app's reply around one of them.
import type {
  PairingCandidate,
  PairingOffer,
  ServerApprover,
  ServerRoleState,
  ServerSnapshot,
  ServerStatus,
} from "./types";

type ServerRole = "session" | "link" | "apps" | "postgres" | "browser" | "automations" | "health" | "updater";

/** 2026-10-02 14:20 PDT, so screenshots and tests are stable. */
export const referenceDate = 1_790_976_000_000;
export const offerCode = "7KQ4M2XD";
export const offerWords = ["copper", "lantern", "meadow", "violet"];

// A QR code of `https://cmux.com/pair?c=7KQ4M2XD#fp=Q4M2XD7KHJ9P3RTV` is not bundled: the gallery
// draws the offer's tile from this small sample, one pixel per module as the app's PNG is.
export const sampleQR =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADUAAAA1AQAAAADJnZ7dAAABp0lEQVR42mP4DwY/GGD0gYBG66UXJBjuB+gx1ojfYLgYIRx3aEoEw8UyG5XYLUA6zIhV60sEw/2iJ2Ury28wHAgFggAJhv8P35Xujv/BcIPtBkvuWwmGe7tWPAh0qGC4YFz4a8qFGwzfd7tYHY+MYHjr4OrjuhLI7/+4zUPhB8O11Hrf8xYzGL5N63UUYLNguFj8+bQvjwTDzaZnHGaTfjAcCzbwZD8pwfBvzbbnzrN2MHxRyLlTmT6D4eMDF7N0RwuGM+KdbIcbZzC8vfm89FJMBcNJ577QgyFA/j2GYu+YHww/pNrYvzRKMPy6unnRtscRDNfNthy7YhzB8PWhpDTLaQuGNwLKgYJHIxhOnnvn17biB8M/h+T1J5dEMPy90uH3xiWC4Zu3lYl28Q2Gy+uXm/lYSTBcCTi39ur+GwyH13CyclZYMLwzU565Vj2C4fGCN0ZmuysYjqusZ5rCAAyPM6dKU+5UMBwI3ht6Y8oNhvuBJwvMYmcwXAz6xlp4cAfDxWCel6J2wPDMmnj3wtMdDPcL4xzMr0swHIg8rigw+wYDWrwAAHFsz/5q78d0AAAAAElFTkSuQmCC";

export function offer(now: number): PairingOffer {
  return { code: offerCode, expiresAt: now + 600_000, words: offerWords, qr: sampleQR };
}

/** The pending server the approver finds with `offerCode`. */
export const candidate: PairingCandidate = {
  code: offerCode,
  name: "build-01",
  os: "Ubuntu 24.04 arm64",
  version: "cmux 0.42.1",
  region: "DE",
  words: offerWords,
  teams: [
    { id: "team_personal", name: "Personal" },
    { id: "team_manaflow", name: "Manaflow" },
  ],
  isChiefBrain: false,
};

export type ServerScenario = "healthyMac" | "batteryLowDisk" | "unpaired" | "linuxHeadless";

const ALL_ROLES: ServerRole[] = ["session", "link", "apps", "postgres", "browser", "automations", "health", "updater"];
const macChecks = [
  "power.onBattery",
  "network.offline",
  "disk.low",
  "lock.pending",
  "sleep.enabled",
  "restart.noAutoRestart",
  "restart.fileVaultWait",
  "encryption.off",
  "postgres.quota",
  "backup.stale",
];
const linuxChecks = ["network.offline", "disk.low", "linger.off", "encryption.off", "postgres.quota", "backup.stale"];
const MIB = 1 << 20;
const GIB = 1 << 30;

function roles(off: ServerRole[] = [], failed: ServerRole[] = [], unavailable: ServerRole[] = []) {
  return ALL_ROLES.map((role) => {
    const state: ServerRoleState = failed.includes(role)
      ? "failed"
      : unavailable.includes(role)
        ? "unavailable"
        : off.includes(role)
          ? "off"
          : "on";
    return { role, state };
  });
}

const apps: ServerSnapshot["appServers"] = [
  { appID: "dev.cmux.tasks", name: "Tasks", state: "running", holdsLease: true, durability: "zero-loss" },
  { appID: "dev.cmux.notes", name: "Notes", state: "running", holdsLease: true, durability: "bounded" },
  { appID: "dev.cmux.hooks", name: "Webhooks", state: "stopped", holdsLease: false, durability: "bounded" },
];

const devices = (now: number): ServerSnapshot["devices"] => [
  { id: "dev_mbp", name: "MacBook Pro", kind: "mac", lastSeen: now - 120_000 },
  { id: "dev_phone", name: "iPhone", kind: "phone", lastSeen: now - 3_600_000 },
  { id: "dev_web", name: "cmux.com", kind: "web", lastSeen: now - 86_400_000 * 2 },
];

export function scenario(name: ServerScenario, now = referenceDate): ServerSnapshot {
  switch (name) {
    case "healthyMac":
      return {
        hostName: "Mac mini",
        platform: "macos",
        enabled: true,
        roles: roles(["automations"]),
        terminals: 14,
        appServers: apps,
        databases: [
          { app: "Tasks", sizeBytes: 412 * MIB, quotaBytes: 5 * GIB },
          { app: "Notes", sizeBytes: 38 * MIB, quotaBytes: 5 * GIB },
        ],
        browser: { state: "running", pages: 3 },
        automations: 4,
        pairing: { state: "paired", team: "Manaflow", owner: "Lawrence", hostID: "host_7f3k2q" },
        devices: devices(now),
        checks: macChecks,
        alerts: [
          {
            check: "sleep.enabled",
            severity: "info",
            title: "Sleep on power adapter is on",
            body: "A scheduled sleep can still stop the server.",
            fix: { title: "Turn Off Sleep", needsAdmin: true, opensSettings: false },
            raisedAt: now - 7_200_000,
          },
          {
            check: "power.onBattery",
            severity: "warning",
            title: "On battery",
            body: "Power came back after 4 minutes.",
            raisedAt: now - 86_000_000,
            resolvedAt: now - 85_760_000,
          },
        ],
        store: { version: "0.42.1", channel: "nightly", pinned: false },
      };
    case "batteryLowDisk":
      return {
        hostName: "MacBook Air",
        platform: "macos",
        enabled: true,
        roles: roles(["automations", "browser"]),
        terminals: 6,
        appServers: apps.slice(0, 2),
        databases: [{ app: "Tasks", sizeBytes: 1_300 * MIB, quotaBytes: 5 * GIB }],
        browser: { state: "off" },
        automations: 0,
        pairing: { state: "paired", team: "Personal", owner: "Lawrence", hostID: "host_2m9w4c" },
        devices: devices(now).slice(0, 2),
        checks: macChecks,
        alerts: [
          {
            check: "power.onBattery",
            severity: "critical",
            title: "On battery, 18%",
            body: "Plug in power. The server stops when the battery runs out.",
            raisedAt: now - 900_000,
          },
          {
            check: "disk.low",
            severity: "warning",
            title: "8.2 GB free",
            body: "Below 10 GB. Builds and databases may fail.",
            fix: { title: "Open Storage", needsAdmin: false, opensSettings: true },
            raisedAt: now - 3_600_000,
          },
          {
            check: "lock.pending",
            severity: "warning",
            title: "Screen locks in 4 minutes",
            body: "A headful browser is running. The lock stops it.",
            fix: { title: "Keep Display Awake", needsAdmin: false, opensSettings: false },
            raisedAt: now - 60_000,
          },
          {
            check: "network.offline",
            severity: "critical",
            title: "No internet",
            body: "The link was down for 3 minutes.",
            raisedAt: now - 14_400_000,
            resolvedAt: now - 14_220_000,
          },
        ],
        store: { version: "0.42.1", channel: "stable", pinned: false },
      };
    case "unpaired":
      return {
        hostName: "Studio",
        platform: "macos",
        enabled: true,
        roles: roles(["link", "automations", "postgres", "browser"]),
        terminals: 2,
        appServers: [],
        databases: [],
        browser: { state: "off" },
        automations: 0,
        pairing: { state: "unpaired", offer: offer(now) },
        devices: [],
        checks: macChecks,
        alerts: [
          {
            check: "restart.noAutoRestart",
            severity: "info",
            title: "No restart after power loss",
            body: "The Mac stays off after a power cut.",
            fix: { title: "Turn On Auto Restart", needsAdmin: true, opensSettings: false },
            raisedAt: now - 30_000,
          },
        ],
        store: { version: "0.42.1", channel: "stable", pinned: false },
      };
    case "linuxHeadless":
      return {
        hostName: "build-01",
        platform: "linux",
        enabled: true,
        roles: roles([], [], ["browser"]),
        terminals: 31,
        appServers: [
          { appID: "dev.cmux.tasks", name: "Tasks", state: "running", holdsLease: true, durability: "zero-loss" },
          { appID: "dev.cmux.ci", name: "CI Runner", state: "crashloop", holdsLease: true, durability: "bounded" },
        ],
        databases: [
          { app: "Tasks", sizeBytes: 4_300 * MIB, quotaBytes: 5 * GIB },
          { app: "CI Runner", sizeBytes: 900 * MIB, quotaBytes: 10 * GIB },
        ],
        browser: { state: "unavailable" },
        automations: 12,
        pairing: { state: "paired", team: "Manaflow", owner: "Lawrence", hostID: "host_9q2r8d" },
        devices: devices(now),
        checks: linuxChecks,
        alerts: [
          {
            check: "linger.off",
            severity: "critical",
            title: "Stops at logout",
            body: "User mode without linger. The server stops when you log out.",
            fix: { title: "Enable Linger", needsAdmin: true, opensSettings: false },
            raisedAt: now - 600_000,
          },
          {
            check: "postgres.quota",
            severity: "warning",
            title: "Tasks at 84% of 5 GB",
            body: "Writes fail at the quota.",
            fix: { title: "Raise Quota", needsAdmin: false, opensSettings: false },
            raisedAt: now - 5_400_000,
          },
          {
            check: "backup.stale",
            severity: "warning",
            title: "No backup in 52 hours",
            body: "The last base backup is from Sep 30.",
            fix: { title: "Back Up Now", needsAdmin: false, opensSettings: false },
            raisedAt: now - 14_400_000,
          },
          {
            check: "encryption.off",
            severity: "info",
            title: "Disk not encrypted",
            body: "The state volume has no LUKS.",
            raisedAt: now - 172_800_000,
          },
        ],
        store: { version: "0.41.7", channel: "stable", pinned: true },
      };
  }
}

export const idleApprover = (): ServerApprover => ({
  session: 1,
  step: "enterCode",
  canApprove: false,
  draft: { code: "", name: "", runChief: false },
});

/** A found server on the Add Server card. */
export const reviewApprover = (overrides: Partial<ServerApprover> = {}): ServerApprover => ({
  session: 1,
  step: "review",
  candidate,
  canApprove: true,
  draft: { code: "7KQ4-M2XD", name: candidate.name, team: candidate.teams[0]!.id, runChief: false },
  ...overrides,
});

/** The app's status around a canned server. */
export function status(name: ServerScenario | null, overrides: Partial<ServerStatus> = {}): ServerStatus {
  return {
    connection: name
      ? { state: "connected" }
      : { state: "unavailable", reason: "This build does not include the server software yet." },
    snapshot: name ? scenario(name) : undefined,
    pending: { switching: false, pairing: false, fixing: [], revoking: [] },
    approver: idleApprover(),
    ...overrides,
  };
}
