import { describe, expect, mock, test } from "bun:test";
import { createElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";

let remoteValue: boolean | undefined;
let flagReads = 0;
mock.module("../app/lib/client-config-flags", () => ({
  useClientConfigFlag: () => { flagReads += 1; return remoteValue; },
  isClientConfigFlagEnabled: (value: boolean | undefined, fallback: boolean) => value ?? fallback,
}));
mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));
const link = ({ href, children }: { href: string; children: ReactNode }) =>
  createElement("a", { href }, children);
mock.module("../i18n/navigation", () => ({ Link: link }));
mock.module("../app/[locale]/components/content-locale-link", () => ({ ContentLocaleLink: link }));
mock.module("posthog-js", () => ({ default: { capture: () => {} } }));

const { NavLinks } = await import("../app/[locale]/components/nav-links");

describe("pricing navigation after rollout", () => {
  test.each([undefined, false, true])("pricing stays visible with remote value %s", (value) => {
    remoteValue = value;
    flagReads = 0;
    const markup = renderToStaticMarkup(createElement(NavLinks));
    expect(markup).toContain('href="/pricing"');
    expect(flagReads).toBe(0);
  });
});
