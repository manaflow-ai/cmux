import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

mock.module("@stackframe/stack", () => ({
  useUser: () => ({
    displayName: "Lawrence",
    primaryEmail: "lawrence@example.com",
    signOut: async () => undefined,
  }),
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
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain("Lawrence");
    expect(html).toContain("lawrence@example.com");
    expect(html).toContain('data-size="24"');
    expect(html).toContain('href="/dashboard/team"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain("signOut");
  });
});
