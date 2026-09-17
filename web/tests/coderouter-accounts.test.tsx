import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import enMessages from "../messages/en.json";

const routerRefresh = mock(() => undefined);

mock.module("next-intl", () => ({
  useTranslations: (namespace: string) => translator(namespace),
  useFormatter: () => ({
    dateTime: (date: Date) => date.toISOString().slice(0, 10),
    relativeTime: () => "2 hours ago",
  }),
  useNow: () => new Date("2026-09-07T12:00:00.000Z"),
}));

mock.module("../i18n/navigation", () => ({
  useRouter: () => ({ refresh: routerRefresh }),
}));

mock.module("@base-ui-components/react/dialog", () => ({
  Dialog: {
    Root: ({ children, open }: { children: React.ReactNode; open: boolean }) =>
      open ? <div>{children}</div> : null,
    Portal: ({ children }: { children: React.ReactNode }) => <>{children}</>,
    Backdrop: () => null,
    Viewport: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Popup: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Title: ({ children }: { children: React.ReactNode }) => <h2>{children}</h2>,
    Description: ({ children }: { children: React.ReactNode }) => <p>{children}</p>,
    Close: ({ children }: { children: React.ReactNode }) => <button>{children}</button>,
  },
}));

const { CoderouterAccountsSection } = await import(
  "../app/[locale]/dashboard/components/coderouter-accounts"
);

const claudeAccount = {
  id: "claude-1",
  kind: "anthropic_oauth" as const,
  label: "work",
  identifier: "sk-ant-oat01-…a1b2",
  region: null,
  modelIds: {},
  state: "active" as const,
  cooldownUntil: null,
  lastFailureCode: null,
  lastUsedAt: "2026-09-07T10:00:00.000Z",
  createdAt: "2026-09-01T00:00:00.000Z",
  updatedAt: "2026-09-01T00:00:00.000Z",
};

const codexAccount = {
  id: "codex-1",
  kind: "codex",
  label: "shared codex",
  createdAt: "2026-08-20T00:00:00.000Z",
  health: { ok: true },
};

const nativeCodexAccount = {
  id: "native-1",
  provider: "codex" as const,
  providerAccountId: "acct_9f3",
  label: "lawrence@example.com",
  state: "active" as const,
  credentialExpiresAt: "2026-09-08T00:00:00.000Z",
  lastFailureCode: null,
  cooldownUntil: null,
  activeSessions: 3,
};

describe("coderouter accounts section", () => {
  test("lists Claude upstream and shared Codex accounts in one table", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "ok", accounts: [codexAccount] }}
      />,
    );

    expect(html).toContain("3 accounts");
    expect(html).toContain("lawrence@example.com");
    expect(html).toContain("3 active sessions");
    expect(html.match(/<ul[^>]*>/g)).toHaveLength(1);
    expect(html).toContain("Claude Code OAuth");
    expect(html).toContain("sk-ant-oat01-…a1b2");
    expect(html).toContain("Codex");
    expect(html).toContain("shared codex");
    expect(html).toContain("last used 2 hours ago");
    expect(html).toContain("added 2026-08-20");
    // Provider rows are text only.
    expect(html).not.toContain("<svg");
  });

  test("offers every account kind in one add panel, OAuth token included", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        claude={{ kind: "ok", accounts: [] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "ok", accounts: [] }}
      />,
    );

    const tabs = [...html.matchAll(/role="tab"[^>]*>([^<]+)</g)].map((match) => match[1]);
    expect(html).toContain('role="tablist"');
    expect(html).toContain('role="tabpanel"');
    // Base UI marks the current tab with data-active; the selected styles key off it.
    const activeTab = html.match(/<button[^>]*\bdata-active=""[^>]*>([^<]+)</)?.[1];
    expect(activeTab).toBe("Anthropic API key");
    expect(html).toMatch(/data-\[active\]:border-foreground/);
    expect(tabs).toEqual([
      "Anthropic API key",
      "Claude Code OAuth",
      "Amazon Bedrock",
      "OpenAI API key",
      "OpenRouter API key",
      "Codex",
      "OpenCode",
    ]);
    expect(html).toContain("No accounts yet");
    expect(html).toContain('name="apiKey"');
  });

  test("hides management controls for members without account rights", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage={false}
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "ok", accounts: [codexAccount] }}
      />,
    );

    expect(html).not.toContain('role="tablist"');
    expect(html).not.toContain(">Remove<");
    expect(html).not.toContain(">Disable<");
    // Provider account identifiers are for account managers only.
    expect(html).not.toContain("acct_9f3");
    expect(html).not.toContain("sk-ant-oat01-…a1b2");
    expect(html).toContain("Claude Code OAuth");
  });

  test("hides the deployment notice from members who cannot manage accounts", () => {
    const render = (canManage: boolean) => renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage={canManage}
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "notConfigured" }}
      />,
    );
    expect(render(true)).toContain("not listed here");
    expect(render(false)).not.toContain("not listed here");
  });

  test("keeps the loaded provider visible when the other one fails", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "error" }}
      />,
    );

    expect(html).toContain("Some accounts could not load");
    expect(html).toContain("Claude Code OAuth");
    expect(html).not.toContain("No accounts yet");
  });

  test("explains a pending shared-account migration without hiding Claude accounts", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "migrationPending" }}
      />,
    );

    expect(html).toContain("Shared accounts temporarily unavailable");
    expect(html).toContain("Claude Code OAuth");
  });
});

function translator(namespace: string) {
  const root = valueAtPath(enMessages, namespace);
  return (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) {
      return (value as Record<string, unknown>)[part];
    }
    return path;
  }, root);
}

function interpolate(message: string, values?: Record<string, unknown>): string {
  if (!values) return message;
  return Object.entries(values).reduce((result, [key, value]) => {
    const plural = result.match(new RegExp(`\\{${key}, plural, ((?:=\\d+ \\{[^}]*\\} )?)one \\{([^}]*)\\} other \\{([^}]*)\\}\\}`));
    if (plural) {
      const exact = plural[1].match(/^=(\d+) \{([^}]*)\} $/);
      const form = exact && Number(exact[1]) === value
        ? exact[2]
        : value === 1 ? plural[2] : plural[3];
      return result.replace(plural[0], form.replaceAll("#", String(value)));
    }
    return result.replaceAll(`{${key}}`, String(value));
  }, message);
}
