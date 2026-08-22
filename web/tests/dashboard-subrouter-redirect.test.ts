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

  test("uses the first team when the query repeats", async () => {
    redirectedTo = null;

    await LegacySubrouterRedirectPage({
      params: Promise.resolve({ locale: "ja" }),
      searchParams: Promise.resolve({ team: ["first", "second"] }),
    });

    expect(redirectedTo).toBe("/ja/dashboard/coderouter?team=first");
  });

  test("omits the query when no team is selected", async () => {
    redirectedTo = null;

    await LegacySubrouterRedirectPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({}),
    });

    expect(redirectedTo).toBe("/en/dashboard/coderouter");
  });
});
