import { describe, expect, test } from "bun:test";
import { routing } from "../i18n/routing";
import { docsSearchPages, docsSearchRoutes } from "../tools/build-docs-search.mjs";

type DocsSearchPage = {
  locale: string;
  href: string;
  path: string;
  title: string;
  description: string;
  sections: Array<{
    texts: string[];
  }>;
};

const pagesPromise = docsSearchPages() as Promise<DocsSearchPage[]>;

describe("docs search index", () => {
  test("builds a searchable page for every locale and docs route", async () => {
    const routes = docsSearchRoutes();
    const pages = await pagesPromise;

    expect(pages).toHaveLength(routes.length);

    for (const locale of routing.locales) {
      const localeRoutes = routes.filter((route) => route.locale === locale);
      expect(pages.filter((page) => page.locale === locale)).toHaveLength(
        localeRoutes.length,
      );

      const gettingStarted = pages.find(
        (page) => page.locale === locale && page.href === "/docs/getting-started",
      );
      expect(gettingStarted?.path).toBe(
        locale === routing.defaultLocale
          ? "/docs/getting-started"
          : `/${locale}/docs/getting-started`,
      );
      expect(gettingStarted?.title.length).toBeGreaterThan(0);
      expect(
        gettingStarted?.sections.some((section) => section.texts.length > 0),
      ).toBe(true);
    }

    expect(
      pages.some((page) => page.locale === "de" && page.href === "/docs/vault"),
    ).toBe(false);
    expect(
      pages.some((page) => page.locale === "de" && page.href === "/docs/task-manager"),
    ).toBe(false);
    expect(
      pages.some((page) => page.locale === "ja" && page.href === "/docs/vault"),
    ).toBe(true);
    expect(
      pages.some((page) => page.locale === "ja" && page.href === "/docs/task-manager"),
    ).toBe(true);
    expect(
      pages.some(
        (page) =>
          page.locale === "de" &&
          page.href === "/docs/agent-integrations/oh-my-pi",
      ),
    ).toBe(false);
    expect(
      pages.some(
        (page) =>
          page.locale === "ja" &&
          page.href === "/docs/agent-integrations/oh-my-pi",
      ),
    ).toBe(true);
  });

  test("indexes Base only for the nightly channel", () => {
    const releaseHrefs = docsSearchRoutes("release").map((route) => route.href);
    const nightlyHrefs = docsSearchRoutes("nightly").map((route) => route.href);

    expect(releaseHrefs).not.toContain("/docs/base");
    expect(nightlyHrefs).toContain("/docs/base");
  });

  test("uses the API page message namespace in every locale", async () => {
    const pages = await pagesPromise;

    for (const locale of routing.locales) {
      const apiPage = pages.find(
        (page) => page.locale === locale && page.href === "/docs/api",
      );

      expect(apiPage?.description.length).toBeGreaterThan(0);
      expect(
        apiPage?.sections.some((section) =>
          section.texts.some((text) => text.includes("workspace.list")),
        ),
      ).toBe(true);
    }
  });

  test("documents Muse Code's own sign-in on the CodeRouter agents page in every locale", async () => {
    const pages = await pagesPromise;

    for (const locale of routing.locales) {
      const agentsPage = pages.find(
        (page) => page.locale === locale && page.href === "/docs/coderouter/agents",
      );
      const texts = agentsPage?.sections.flatMap((section) => section.texts) ?? [];

      // Search aliases already contain "Muse Code" and "muse login", so look
      // for the one translated paragraph that carries the recovery steps.
      const recovery = texts.find(
        (text) => text.includes("muse usage") && text.includes("muse logout"),
      );
      for (const term of ["Muse Code", "CodeRouter", "muse login", "META_API_KEY"]) {
        expect(recovery).toContain(term);
      }
    }
  });

  test("localizes the notification preview schema description in every locale", async () => {
    for (const locale of routing.locales) {
      const messages = (await import(`../messages/${locale}.json`)).default as {
        docs: {
          configuration: {
            schemaDescriptions: {
              sidebar: { notificationMessageLineLimit?: string };
            };
          };
        };
      };

      expect(
        messages.docs.configuration.schemaDescriptions.sidebar
          .notificationMessageLineLimit,
      ).toBeTruthy();
    }
  });
});
