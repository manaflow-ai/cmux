import { describe, expect, mock, test } from "bun:test";
import { NextIntlClientProvider } from "next-intl";
import type React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { loadMessages } from "../i18n/messages";
import type { SerializedVaultSessionListRow } from "../services/vault/sessionList";
import { summarizeVaultAgents } from "../services/vault/summary";

mock.module("@tanstack/react-virtual", () => ({
  useVirtualizer: ({ count }: { count: number }) => ({
    getVirtualItems: () =>
      Array.from({ length: count }, (_, index) => ({ index, size: 72, start: index * 72 })),
    getTotalSize: () => count * 72,
  }),
}));

const realRouter = await import("@tanstack/react-router");
mock.module("@tanstack/react-router", () => ({
  ...realRouter,
  Link: ({ to, children, ...props }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) => (
    <a href={to} {...props}>{children}</a>
  ),
  useNavigate: () => () => Promise.resolve(),
}));

const { SessionsTableView } = await import("../dashboard-app/screens/vault/sessions-screen");
const { VaultOverviewView } = await import("../dashboard-app/screens/vault/vault-overview");
const { VaultCliAuthView } = await import("../dashboard-app/screens/vault/cli-auth-screen");
const { VaultSessionView } = await import("../dashboard-app/screens/vault/session-screen");
const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");

const messages = await loadMessages("en");

function render(element: React.ReactNode) {
  return renderToStaticMarkup(
    <QueryClientProvider client={new QueryClient()}>
      <NextIntlClientProvider locale="en" messages={messages} timeZone="UTC">
        {element}
      </NextIntlClientProvider>
    </QueryClientProvider>,
  );
}

const sessionRow: SerializedVaultSessionListRow = {
  id: "session-1",
  agent: "codex",
  agentSessionId: "session-id-abcdefghijklmnopqrstuvwxyz",
  relPath: "project",
  cwd: "/Users/test/project",
  latestSha256: "sha256",
  sizeBytes: 1536,
  compressedSizeBytes: 768,
  snapshotCount: 1,
  firstUploadedAt: "2026-07-04T12:00:00.000Z",
  lastUploadedAt: "2026-07-04T12:00:30.000Z",
};

function table(overrides: Partial<React.ComponentProps<typeof SessionsTableView>> = {}) {
  return render(
    <SessionsTableView
      query=""
      onQueryChange={() => undefined}
      rows={[sessionRow]}
      status="end"
      now={new Date("2026-07-04T12:01:00.000Z")}
      scrollRef={() => undefined}
      scrollElement={null}
      onNearEnd={() => undefined}
      onNavigate={() => undefined}
      {...overrides}
    />,
  );
}

describe("Vault sessions table", () => {
  test("renders relative upload time against the given clock", () => {
    const html = table();
    expect(html).toContain("30 seconds ago");
    expect(html).toContain("project");
    expect(html).toContain("1.5 KB");
    expect(html).toContain('href="/dashboard/vault"');
    expect(html).toContain("End of sessions");
  });

  test.each([
    ["loading", "Loading more..."],
    ["error", "Could not load more sessions."],
    ["empty", "No sessions match these filters."],
  ] as const)("the trailing row reports the %s state", (status, text) => {
    const html = table({ status, rows: status === "empty" ? [] : [sessionRow] });
    expect(html).toContain(text);
  });
});

describe("Vault overview", () => {
  test("shows the sync command when nothing is synced", () => {
    const html = render(<VaultOverviewView summary={summarizeVaultAgents([])} />);
    expect(html).toContain("cmux-vault sync");
  });

  test("shows totals and per-agent counts, largest first", () => {
    const summary = summarizeVaultAgents([
      { agent: "claude", sessionCount: 2, rawBytes: 1024, compressedBytes: 512, lastUploadedAt: new Date("2026-07-01T00:00:00Z") },
      { agent: "codex", sessionCount: 5, rawBytes: 2048, compressedBytes: 1024, lastUploadedAt: new Date("2026-07-03T00:00:00Z") },
    ]);
    expect(summary).toMatchObject({
      sessionCount: 7,
      rawBytes: 3072,
      compressedBytes: 1536,
      lastUploadedAt: "2026-07-03T00:00:00.000Z",
      agents: [{ agent: "codex", sessionCount: 5 }, { agent: "claude", sessionCount: 2 }],
    });
    const html = render(<VaultOverviewView summary={summary} />);
    expect(html).toContain("5 codex · 2 claude");
    expect(html).not.toContain("cmux-vault sync");
  });
});

describe("Vault CLI approval", () => {
  test("names CodeRouter only when the pending request says so", () => {
    const vault = render(<VaultCliAuthView initialCode="ABCD2345" coderouter={false} />);
    const coderouter = render(<VaultCliAuthView initialCode="ABCD2345" coderouter />);
    const cliAuth = (messages.vault as Record<string, Record<string, string>>).cliAuth!;
    expect(vault).toContain(cliAuth.title!);
    expect(coderouter).toContain(cliAuth.coderouterTitle!);
    expect(coderouter).toContain('value="ABCD2345"');
  });
});

describe("Vault session detail", () => {
  test("renders metadata, resume command, and snapshots", () => {
    const html = render(
      <VaultSessionView
        session={{
          id: "11111111-1111-4111-8111-111111111111",
          agent: "codex",
          agentSessionId: "agent-session",
          cwd: null,
          sizeBytes: 2048,
          compressedSizeBytes: null,
          firstUploadedAt: "2026-07-01T00:00:00.000Z",
          lastUploadedAt: "2026-07-02T00:00:00.000Z",
          downloadUrl: null,
          snapshots: [{ sha256: "a".repeat(64), sizeBytes: 2048, compressedSizeBytes: 900, uploadedAt: "2026-07-02T00:00:00.000Z" }],
        }}
      >
        <p>transcript</p>
      </VaultSessionView>,
    );
    expect(html).toContain("cmux-vault resume agent-session");
    expect(html).toContain('href="/dashboard/vault/sessions"');
    expect(html).toContain("transcript");
    expect(html).toContain("2 KB");
  });
});
