import { describe, expect, mock, test } from "bun:test";

let redirectedTo: string | null = null;

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    redirectedTo = target;
  },
}));

mock.module("@/i18n/navigation", () => ({
  getPathname: ({
    locale,
    href,
  }: {
    locale: string;
    href: { pathname: string; query?: { team: string } };
  }) => `/${locale}${href.pathname}${
    href.query ? `?team=${encodeURIComponent(href.query.team)}` : ""
  }`,
}));

const { default: LegacySubrouterRedirectPage } = await import(
  "../app/[locale]/dashboard/subrouter/page"
);

describe("legacy subrouter dashboard URL", () => {
  test("redirects to coderouter and preserves the selected team", async () => {
    redirectedTo = null;

    await LegacySubrouterRedirectPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ team: "team one" }),
    });

    expect(redirectedTo).toBe("/en/dashboard/coderouter?team=team%20one");
  });
});
