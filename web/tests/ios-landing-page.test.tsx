import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AnchorHTMLAttributes, ReactNode } from "react";
import { createTranslator } from "use-intl/core";
import enMessages from "../messages/en.json";

mock.module("next-intl", () => ({
  useTranslations: (namespace?: string) =>
    createTranslator({
      locale: "en",
      messages: enMessages,
      namespace: namespace as never,
    }),
}));

mock.module("next-intl/server", () => ({
  getTranslations: async (namespace?: string | { namespace?: string }) =>
    createTranslator({
      locale: "en",
      messages: enMessages,
      namespace: (typeof namespace === "string" ? namespace : namespace?.namespace) as never,
    }),
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: AnchorHTMLAttributes<HTMLAnchorElement> & {
    href: string;
    children?: ReactNode;
  }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
}));

mock.module("../app/[locale]/components/site-header", () => ({
  SiteHeader: () => <header />,
}));

mock.module("../app/[locale]/components/github-button", () => ({
  GitHubButton: () => <a href="https://github.com/manaflow-ai/cmux">GitHub</a>,
}));

mock.module("../app/[locale]/components/reveal-image", () => ({
  RevealImage: ({ alt }: { alt: string }) => <img alt={alt} />,
}));

const { default: IosLanding } = await import(
  "../app/[locale]/(landing)/ios/page"
);

describe("iOS landing page", () => {
  test("sends both TestFlight CTAs to the current enrollment route", () => {
    const html = renderToStaticMarkup(<IosLanding />);

    expect(html.match(/href="\/dashboard\/testflight"/g)).toHaveLength(2);
    expect(html).not.toContain("founders-edition");
  });
});
