import { expect, test } from "bun:test";
import { createTranslator } from "next-intl";
import { routing } from "../i18n/routing";

test("Cloud CLI guidance renders machine targets as text in every locale", async () => {
  for (const locale of routing.locales) {
    const messages = (await import(`../messages/${locale}.json`)).default;
    const errors: Error[] = [];
    const t = createTranslator({ locale, messages, namespace: "docs.cloudCli", onError: error => errors.push(error) });
    expect(t("nextTargets", { machineTarget: "machine:<id>" })).toContain("machine:<id>");
    expect(errors).toEqual([]);
  }
});

test("docs search includes every generated Cloud command", async () => {
  const { docsSearchPages } = await import("../tools/build-docs-search.mjs");
  const catalog = (await import("../app/[locale]/(landing)/docs/cloud/cli/actions.json")).default;
  const pages = await docsSearchPages();
  const page = pages.find((entry: { locale: string; href: string }) => entry.locale === "en" && entry.href === "/docs/cloud/cli");
  expect(page).toBeDefined();
  if (!page) throw new Error("Cloud CLI page missing from docs search");
  const messages = (await import("../messages/en.json")).default;
  expect(page.description).toBe(messages.docs.cloudCli.metaDescription);
  expect(page.description).not.toContain("cmux vm");
  const text = page.sections.flatMap((section: { texts: string[] }) => section.texts).join("\n");
  for (const { command, id } of catalog.actions) {
    expect(text).toContain(command);
    expect(text).toContain(id);
  }
});
