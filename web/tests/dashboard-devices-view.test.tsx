// Device dashboard view: renders the joined registry + control-plane data
// with the spec's derived display states — revoked stays listed and flagged,
// seeded shows the unverified warning, silent seeded rows display as stale,
// retired rows hide by default, below-floor versions surface the
// update-required callout, and per-device sync state compares lastAckedRev to
// the head revision.

import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import enMessages from "../messages/en.json";

mock.module("next-intl", () => ({
  useTranslations: (namespace?: string) => translator(namespace),
  useLocale: () => "en",
}));

import { DevicesView } from "../app/[locale]/dashboard/devices/devices-view";
import {
  versionBelowFloor,
  type DeviceDashboardData,
  type DeviceDashboardEntry,
} from "../services/devices/dashboard";

const NOW_ISO = "2026-09-01T12:00:00.000Z";

function entry(overrides: Partial<DeviceDashboardEntry>): DeviceDashboardEntry {
  return {
    endpointId: "e".repeat(64),
    displayName: null,
    platform: "mac",
    platformInferred: false,
    tag: "default",
    clientNamespace: "irx",
    deviceId: null,
    lastSeenAt: NOW_ISO,
    registryRevokedAt: null,
    listAuth: {
      listed: true,
      status: "active",
      revoked: false,
      appVersion: "0.66.0",
      releaseTrack: "stable",
      capabilities: [],
      lastConfirmedAt: NOW_ISO,
      lastAckedRev: 12,
      connected: false,
    },
    ...overrides,
  };
}

function data(devices: DeviceDashboardEntry[]): DeviceDashboardData {
  return {
    controlPlaneAvailable: true,
    rev: 12,
    ttlSeconds: 86_400,
    minimumSupportedVersion: { mac: "0.60.0", ios: "1.4.0" },
    devices,
  };
}

function render(payload: DeviceDashboardData): string {
  return renderToStaticMarkup(
    <DevicesView initialData={payload} initialNowIso={NOW_ISO} />,
  );
}

describe("DevicesView", () => {
  test("renders an active connected Mac with synced state and its actions", () => {
    const html = render(data([
      entry({
        endpointId: "a".repeat(64),
        displayName: "Studio Mac",
        listAuth: {
          ...entry({}).listAuth!,
          connected: true,
          releaseTrack: "internal",
        },
      }),
    ]));
    expect(html).toContain("Studio Mac");
    expect(html).toContain("synced · r12");
    expect(html).toContain("0.66.0 · internal");
    expect(html).toContain(">Revoke<");
    // Connected devices are not offered Remove (cleanup is for dead entries).
    expect(html).not.toContain(">Remove<");
  });

  test("revoked device stays listed, flagged, with a Restore action", () => {
    const html = render(data([
      entry({
        endpointId: "b".repeat(64),
        displayName: "Lost iPhone",
        platform: "ios",
        listAuth: {
          ...entry({}).listAuth!,
          revoked: true,
          releaseTrack: "appstore",
          appVersion: "1.5.0",
        },
      }),
    ]));
    expect(html).toContain("Lost iPhone");
    expect(html).toContain(">revoked<");
    expect(html).toContain(">Restore<");
    expect(html).toContain("blocked from connecting");
  });

  test("silent seeded row displays as stale with the unverified explainer", () => {
    const html = render(data([
      entry({
        endpointId: "c".repeat(64),
        displayName: "Old Mac mini",
        lastSeenAt: "2026-08-01T00:00:00.000Z",
        listAuth: {
          ...entry({}).listAuth!,
          status: "seeded",
          lastAckedRev: null,
          appVersion: null,
          releaseTrack: null,
        },
      }),
    ]));
    expect(html).toContain(">△ stale<");
    expect(html).toContain("hasn&#x27;t checked in on the new system");
    expect(html).toContain("never synced");
  });

  test("retired rows hide by default behind the Show removed toggle", () => {
    const html = render(data([
      entry({ displayName: "Current Mac" }),
      entry({
        endpointId: "d".repeat(64),
        displayName: "Ancient MacBook",
        listAuth: { ...entry({}).listAuth!, status: "retired" },
      }),
    ]));
    expect(html).toContain("Current Mac");
    expect(html).not.toContain("Ancient MacBook");
    expect(html).toContain("Show removed (1)");
  });

  test("below-floor versions surface the update-required callout", () => {
    const html = render(data([
      entry({
        displayName: "Behind Mac",
        listAuth: { ...entry({}).listAuth!, appVersion: "0.41.0" },
      }),
    ]));
    expect(html).toContain("Updates required");
    expect(html).toContain("Behind Mac runs 0.41.0");
    expect(html).toContain("update required");
  });

  test("behind-on-sync device shows acked vs head revision", () => {
    const html = render(data([
      entry({
        displayName: "Sleepy Mac",
        listAuth: { ...entry({}).listAuth!, lastAckedRev: 9 },
      }),
    ]));
    expect(html).toContain("behind · r9 of r12");
  });

  test("registry-only device renders as not enrolled without actions", () => {
    const html = render(data([
      entry({
        endpointId: "f".repeat(64),
        displayName: "Legacy Mac",
        listAuth: null,
      }),
    ]));
    expect(html).toContain("Legacy Mac");
    expect(html).toContain(">not enrolled<");
    expect(html).not.toContain(">Revoke<");
  });

  test("control-plane outage shows the degraded banner", () => {
    const html = render({
      ...data([entry({ displayName: "Some Mac" })]),
      controlPlaneAvailable: false,
      rev: null,
      minimumSupportedVersion: null,
    });
    expect(html).toContain("Live device status unavailable");
    expect(html).toContain("Some Mac");
  });

  test("version spread aggregates track + version straight from the list", () => {
    const html = render(data([
      entry({ displayName: "Mac A" }),
      entry({
        endpointId: "9".repeat(64),
        displayName: "Mac B",
      }),
      entry({
        endpointId: "8".repeat(64),
        displayName: "Phone",
        platform: "ios",
        listAuth: {
          ...entry({}).listAuth!,
          releaseTrack: "appstore",
          appVersion: "1.5.0",
        },
      }),
    ]));
    expect(html).toContain("Version spread");
    expect(html).toContain("mac · stable · 0.66.0");
    expect(html).toContain("ios · appstore · 1.5.0");
  });
});

describe("versionBelowFloor", () => {
  test("compares dotted numeric segments", () => {
    expect(versionBelowFloor("0.41.0", "0.60.0")).toBe(true);
    expect(versionBelowFloor("0.60.0", "0.60.0")).toBe(false);
    expect(versionBelowFloor("0.60.1", "0.60.0")).toBe(false);
    expect(versionBelowFloor("1.0", "0.99.99")).toBe(false);
    expect(versionBelowFloor("0.9", "0.10")).toBe(true);
  });
});

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
  t.raw = (key: string) => valueAtPath(root, key);
  t.rich = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
  return t;
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) {
      return (value as Record<string, unknown>)[part];
    }
    return path;
  }, root);
}

function interpolate(
  message: string,
  values?: Record<string, unknown>,
): string {
  if (!values) return message;
  return Object.entries(values).reduce(
    (result, [key, value]) => result.replaceAll(`{${key}}`, String(value)),
    message,
  );
}
