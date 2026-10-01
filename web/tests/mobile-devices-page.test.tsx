import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { withDashboardRouter } from "./helpers/dashboard-router";
import { NextIntlClientProvider } from "next-intl";
import { loadMessages } from "../i18n/messages";
import { locales } from "../i18n/routing";
import type { ReactNode } from "react";

// The dashboard shell's navigation (the `/dashboard/mobile-devices` link) and
// the legacy `/dashboard/iroh` redirect are covered by the shell and redirect
// suites; this file covers the Mobile devices screen only.
mock.module("../dashboard-app/shell/dashboard-team-scope", () => ({
  useDashboardTeamScope: () => ({
    status: "ready",
    selected: { id: "fixture-team", name: "Fixture team" },
    teams: [{ id: "fixture-team", name: "Fixture team" }],
    switchTeam: async () => {},
  }),
}));
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({}),
  useUser: () => ({ selectedTeam: { id: "fixture-team" }, useTeams: () => [{ id: "fixture-team", displayName: "Personal" }] }),
}));
const { ConnectionError, DeviceCard, EmptyDevices, LoadingState, MobileDevicesDashboard, MobileDevicesPage, RelaySettings } = await import(
  "../dashboard-app/screens/mobile-devices/mobile-devices-dashboard"
);

describe("mobile devices dashboard", () => {
  test("uses the dashboard-wide team scope instead of rendering a page picker", async () => {
    const messages = await loadMessages("en");
    const html = renderToStaticMarkup(
      <NextIntlClientProvider locale="en" messages={messages} timeZone="UTC">
        <MobileDevicesDashboard userId="fixture-user" />
      </NextIntlClientProvider>,
    );
    expect(html).toContain("Fixture team");
    expect(html).toContain("Team: Fixture team");
    expect(html).not.toContain("Team scope active");
    expect(html).not.toContain("mobile-devices-team");
    expect(html).not.toContain("<select");
  });

  test("covers the simplified populated, empty, recovery, and relay states", async () => {
    const messages = await loadMessages("en");
    const device = {
      deviceRecordId: "device-record",
      descriptor: {
        identity: { deviceId: "device-12345678" },
        metadata: { displayName: "Lawrence's iPhone", platform: "iOS", appVersion: "1.2.3" },
      },
      revision: 7,
      revoked: false,
    } as const;
    const render = (element: ReactNode) => renderToStaticMarkup(
      <NextIntlClientProvider locale="en" messages={messages} timeZone="UTC">{element}</NextIntlClientProvider>,
    );
    const populated = render(<DeviceCard device={device} canRevoke busy={false} failed={false} onRevoke={() => {}} />);
    expect(populated).toContain('data-device-id="device-record"');
    expect(populated).toContain("Lawrence&#x27;s iPhone");
    expect(populated).toContain("Active");
    expect(populated).toContain("Revoke access");
    expect(populated).toContain('aria-hidden="true"');

    expect(render(<EmptyDevices />)).toContain("No connected devices yet");
    expect(render(<LoadingState label="Loading devices…" />)).toContain('role="status"');
    expect(render(<ConnectionError onRetry={() => {}} />)).toContain("Try again");
    const relay = render(<RelaySettings relayURLs={["https://relay.example"]} controllerRef={{ current: null }} />);
    expect(relay).toContain("<details");
    expect(relay).toContain("Relay settings");
    expect(relay).toContain("Save relay settings");
  });

  test.each(locales)("renders product naming in %s", async (locale) => {
    const messages = await loadMessages(locale);
    const { element } = await withDashboardRouter(
      <NextIntlClientProvider locale={locale} messages={messages} timeZone="UTC">
        <MobileDevicesPage userId="fixture-user" />
      </NextIntlClientProvider>,
      "/dashboard/mobile-devices",
    );
    const html = renderToStaticMarkup(element);
    expect(html).toContain('data-testid="mobile-devices-dashboard"');
    expect(html).not.toMatch(/iroh|Stack|Cloudflare|Durable Object/i);
    const title = (messages.dashboard as Record<string, Record<string, string>>).mobileDevices!.title!;
    expect(html).toContain(title);
  });
});
