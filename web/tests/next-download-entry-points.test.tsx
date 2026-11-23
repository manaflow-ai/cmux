import { describe, expect, mock, test } from "bun:test";
import { cloneElement, isValidElement, type ReactElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createTranslator } from "use-intl/core";
import { locales, type Locale } from "../i18n/routing";
import enMessages from "../messages/en.json";

type Messages = typeof enMessages;
const messagesByLocale = {} as Record<Locale, Messages>;
for (const locale of locales) {
  messagesByLocale[locale] = (await import(`../messages/${locale}.json`)).default as Messages;
}

let currentLocale: Locale = "en";

function translator(namespace?: string) {
  const t = createTranslator({
    locale: currentLocale,
    messages: messagesByLocale[currentLocale],
    namespace: namespace as never,
  });
  return t;
}

mock.module("next-intl", () => ({
  useTranslations: (namespace?: string) => translator(namespace),
  useLocale: () => currentLocale,
}));

const PlainLink = ({ href, children, ...rest }: { href: string; children?: ReactNode }) => (
  <a href={href} {...rest}>
    {children}
  </a>
);

mock.module("../i18n/navigation", () => ({
  Link: PlainLink,
  usePathname: () => "/",
  useRouter: () => ({ push: () => undefined }),
}));

// The Download menu's popup mounts only while open. These stand-ins render
// every part in place so the menu's full item list renders statically.
const Pass = ({ children }: { children?: ReactNode }) => <>{children}</>;
mock.module("@base-ui-components/react/menu", () => ({
  Menu: {
    Root: Pass,
    Trigger: ({ children }: { children?: ReactNode }) => <button type="button">{children}</button>,
    Portal: Pass,
    Positioner: Pass,
    Popup: ({ children }: { children?: ReactNode }) => <div role="menu">{children}</div>,
    Item: ({ render, children }: { render?: ReactElement; children?: ReactNode }) =>
      render && isValidElement(render) ? (
        cloneElement(render as ReactElement<{ children?: ReactNode; role?: string }>, { role: "menuitem" }, children)
      ) : (
        <div role="menuitem">{children}</div>
      ),
    Separator: () => <hr />,
    Group: Pass,
    GroupLabel: Pass,
  },
}));

mock.module("../app/[locale]/components/waitlist-dialog", () => ({
  WaitlistDialog: () => null,
}));

const { DownloadButton } = await import("../app/[locale]/components/download-button");
const { NextCallout } = await import("../app/[locale]/components/next-callout");

function render(node: ReactElement, locale: Locale = "en"): string {
  currentLocale = locale;
  return renderToStaticMarkup(node);
}

function menuItems(html: string): string[] {
  return [...html.matchAll(/<a[^>]*role="menuitem"[^>]*>/g)].map((m) => m[0]);
}

describe("cmux NEXT entry points on cmux.com", () => {
  test("the Download menu offers cmux NEXT, right after the Mac download", () => {
    const html = render(<DownloadButton location="hero" />);
    const items = menuItems(html);
    const hrefs = items.map((tag) => tag.match(/href="([^"]*)"/)?.[1]);
    expect(hrefs).toContain("/next");
    expect(hrefs.indexOf("/next")).toBe(1);
    expect(html).toContain("cmux NEXT");
  });

  test("the home page hero links cmux NEXT", () => {
    const html = render(<NextCallout />);
    expect(html).toContain('href="/next"');
    expect(html).toContain(">cmux NEXT</a>");
  });

  test("the hero line and menu entry are translated in every locale", () => {
    for (const locale of locales) {
      const callout = messagesByLocale[locale].home.nextCallout;
      expect(callout).toBeString();
      expect(callout).toContain("<link>cmux NEXT</link>");
      if (locale !== "en") {
        expect(callout).not.toBe(enMessages.home.nextCallout);
      }
      const html = render(<NextCallout />, locale);
      expect(html).toContain('href="/next"');
      const menu = render(<DownloadButton location="hero" />, locale);
      expect(menu).toContain(messagesByLocale[locale].next.title);
    }
  });
});
