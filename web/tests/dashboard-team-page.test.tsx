import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

let signedIn = true;
let stackConfigured = true;
let redirectedTo: string | null = null;

mock.module("@stackframe/stack", () => ({
  AccountSettings: () => (
    <section data-testid="stack-account-settings">
      profile, security, sessions, teams, and invitations
    </section>
  ),
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    redirectedTo = target;
    throw new Error(`redirect:${target}`);
  },
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
