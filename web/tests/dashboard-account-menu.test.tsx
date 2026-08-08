import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

let currentUser: {
  displayName: string;
  primaryEmail: string;
  signOut: () => Promise<void>;
} | null = null;

mock.module("@stackframe/stack", () => ({
  useUser: () => currentUser,
  UserAvatar: ({ size }: { size: number }) => (
    <span data-testid="avatar" data-size={size} />
  ),
}));

mock.module("@base-ui-components/react/menu", () => ({
  Menu: {
    Root: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Trigger: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
      <button {...props}>{children}</button>
    ),
    Portal: ({ children }: { children: React.ReactNode }) => <>{children}</>,
    Positioner: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Popup: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Item: ({
      children,
      render,
      ...props
    }: React.HTMLAttributes<HTMLElement> & { render?: React.ReactElement }) =>
      render
        ? <span {...props}>{render}{children}</span>
        : <button {...props}>{children}</button>,
    Separator: () => <hr />,
  },
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) => (
    <a href={href} {...props}>{children}</a>
  ),
}));

const { DashboardAccountMenu } = await import(
  "../app/[locale]/dashboard/dashboard-account-menu"
);

describe("dashboard account menu", () => {
  test("matches the chatmux identity row and exposes working account actions", () => {
    currentUser = {
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
    };
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain("Lawrence");
    expect(html).toContain("lawrence@example.com");
    expect(html).toContain('data-size="24"');
    expect(html).toContain('href="/dashboard/team"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain("signOut");
  });

  test("uses the unlocalized auth handler and names the compact sign-in link", () => {
    currentUser = null;
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain('aria-label="signIn"');
    expect(html).toContain('href="/handler/sign-in?');
    expect(html).toContain("dashboard");
    expect(html).not.toContain("/en/handler/sign-in");
  });
});
