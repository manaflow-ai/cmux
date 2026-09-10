import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import {
  TEST_STACK_PROJECT_ID,
  nextHeadersMock,
} from "./helpers/dashboard-session-mock";
import { renderSettled } from "./helpers/render-stream";

const previousStackProjectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = TEST_STACK_PROJECT_ID;
afterAll(() => {
  if (previousStackProjectId === undefined) {
    delete process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
  } else {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = previousStackProjectId;
  }
});

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

mock.module("next/headers", () =>
  nextHeadersMock({
    refreshToken: () => "refresh-1",
    // Middleware forwards the destination for the sign-in redirect.
    headers: () => new Headers({ "x-cmux-dashboard-return-path": "/dashboard/team" }),
  }),
);

mock.module("next/cache", () => ({
  cacheLife: () => undefined,
}));

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
    getUser: async () => signedIn ? { id: "user-1", isAnonymous: false } : null,
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
    expect(renderToStaticMarkup(page)).toContain(
      'data-testid="dashboard-section-skeleton"',
    );
    const html = await renderSettled(page);

    expect(html).toContain('data-testid="stack-account-settings"');
    expect(html).toContain("teams, and invitations");
    expect(redirectedTo).toBeNull();
  });

  test("preserves the team settings return path when signed out", async () => {
    signedIn = false;

    const html = await renderSettled(await DashboardTeamPage({
      params: Promise.resolve({ locale: "en" }),
    }));

    expect(html).not.toContain('data-testid="stack-account-settings"');
    expect(redirectedTo).toContain("/handler/sign-in");
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
