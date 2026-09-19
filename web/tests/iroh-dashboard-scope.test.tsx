import { expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

mock.module("next-intl", () => ({ useTranslations: () => (key: string) => key }));
mock.module("@stackframe/stack", () => ({ useStackApp: () => ({ getAuthJson: async () => ({ accessToken: null }) }) }));
mock.module("../app/[locale]/dashboard/dashboard-team-scope", () => ({
  useDashboardTeamScope: () => ({
    status: "ready",
    selected: { id: "personal-user-id", name: "Personal", personal: true },
  }),
}));
const { IrohDashboard } = await import("../app/[locale]/dashboard/iroh/iroh-dashboard");

test("personal account scope asks for a real team instead of opening an invalid device session", () => {
  const html = renderToStaticMarkup(<IrohDashboard userId="personal-user-id" />);
  expect(html).toContain("selectTeam");
  expect(html).not.toContain('data-testid="iroh-dashboard"');
});
