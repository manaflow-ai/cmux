import { describe, expect, test } from "bun:test";
import { routing } from "../i18n/routing";
import {
  fallbackContentLocales,
  featureWorkflowContentLocales,
} from "../i18n/locale-availability";
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

    for (const locale of routing.locales) {
      const hasVault = pages.some(
        (page) => page.locale === locale && page.href === "/docs/vault",
      );
      const hasTaskManager = pages.some(
        (page) => page.locale === locale && page.href === "/docs/task-manager",
      );
      const hasOhMyPi = pages.some(
        (page) =>
          page.locale === locale &&
          page.href === "/docs/agent-integrations/oh-my-pi",
      );
      expect(hasVault).toBe(featureWorkflowContentLocales.includes(locale as never));
      expect(hasTaskManager).toBe(
        featureWorkflowContentLocales.includes(locale as never),
      );
      expect(hasOhMyPi).toBe(fallbackContentLocales.includes(locale as never));
    }
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
