import { expect, test } from "bun:test";
import { createTranslator } from "next-intl";
import { routing } from "../i18n/routing";

test("Cloud quickstart renders machine targets as text in every locale", async () => {
  for (const locale of routing.locales) {
    const messages = (await import(`../messages/${locale}.json`)).default;
    const errors: Error[] = [];
    const t = createTranslator({ locale, messages, namespace: "docs.cloudOverview", onError: error => errors.push(error) });
    expect(t("nextPending", { machineTarget: "machine:<id>" })).toContain("machine:<id>");
    expect(errors).toEqual([]);
  }
});
