import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

let signedIn = true;
let stackConfigured = true;
let redirectedTo: string | null = null;

mock.module("@stackframe/stack", () => ({
  AccountSettings: () => (
    <section data-testid="stack-account-settings">
      profile, security, sessions, teams, and invitations
    </section>
  ),
  useUser: () => null,
  UserAvatar: () => <span data-testid="avatar" />,
  TeamSwitcher: () => <span data-testid="team-switcher" />,
}));

mock.module("next/navigation", () => {
  const navigation = createNextNavigationMock((target: unknown) => {
    redirectedTo = String(target);
    throw new Error(`redirect:${target}`);
  });
  return navigation;
});

mock.module("@tanstack/react-query", () => ({
  useQuery: () => ({ data: undefined, isPending: true, isError: false }),
  useQueryClient: () => ({
    setQueryData: () => undefined,
    invalidateQueries: async () => undefined,
  }),
}));

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => stackConfigured,
  getStackServerApp: () => ({
    getUser: async () => signedIn ? { id: "user-1" } : null,
  }),
}));

mock.module("../app/lib/vault-auth", () => ({
  localizedVaultPath: (_locale: string, path: string) => path,
  vaultSignInHref: (path: string) => `/handler/sign-in?after_auth_return_to=${path}`,
}));

const { default: DashboardTeamPage } = await import(
  "../app/[locale]/dashboard/team/page"
);

describe("dashboard team settings", () => {
  beforeEach(() => {
    signedIn = true;
    stackConfigured = true;
    redirectedTo = null;
  });

  test("renders Stack's complete account and team settings", async () => {
    const page = await DashboardTeamPage({
      params: Promise.resolve({ locale: "en" }),
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain('data-testid="stack-account-settings"');
    expect(html).toContain("teams, and invitations");
    expect(redirectedTo).toBeNull();
  });

  test("preserves the team settings return path when signed out", async () => {
    signedIn = false;

    await expect(DashboardTeamPage({
      params: Promise.resolve({ locale: "en" }),
    })).rejects.toThrow("redirect:/handler/sign-in");
    expect(redirectedTo).toContain("/dashboard/team");
  });

  test("preserves the active locale when Stack is unavailable", async () => {
    stackConfigured = false;

    await expect(DashboardTeamPage({
      params: Promise.resolve({ locale: "ja" }),
    })).rejects.toThrow("redirect:/ja");
    expect(redirectedTo).toBe("/ja");
  });
});
