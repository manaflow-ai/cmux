import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import type { SerializedVaultSessionListRow } from "../services/vault/sessionList";

mock.module("@tanstack/react-virtual", () => ({
  useVirtualizer: ({ count }: { count: number }) => ({
    getVirtualItems: () =>
      Array.from({ length: count }, (_, index) => ({
        index,
        size: 72,
        start: index * 72,
      })),
    getTotalSize: () => count * 72,
  }),
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({ href, children, ...props }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
  usePathname: () => "/dashboard/vault/sessions",
  useRouter: () => ({
    push: mock(() => undefined),
    replace: mock(() => undefined),
  }),
}));

const { SessionsTable } = await import("../app/[locale]/dashboard/vault/sessions/sessions-table");

describe("Vault sessions table hydration", () => {
  test("uses the server render timestamp for the hydration pass", () => {
    const initialNowIso = "2026-07-04T12:01:00.000Z";
    const serverHtml = withFixedNow("2026-07-04T12:01:00.000Z", () =>
      renderSessionsTable(initialNowIso),
    );
    const hydrationHtml = withFixedNow("2026-07-04T12:02:00.000Z", () =>
      renderSessionsTable(initialNowIso),
    );

    expect(serverHtml).toContain("30 seconds ago");
    expect(hydrationHtml).toBe(serverHtml);
  });
});

function renderSessionsTable(initialNowIso: string) {
  return renderToStaticMarkup(
    <SessionsTable
      initialQuery=""
      initialRows={[sessionRow]}
      initialNextCursor={null}
      initialNowIso={initialNowIso}
    />,
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

function withFixedNow<T>(iso: string, operation: () => T): T {
  const RealDate = Date;
  const fixedTime = new RealDate(iso).getTime();

  globalThis.Date = class extends RealDate {
    constructor(...args: unknown[]) {
      if (args.length === 0) {
        super(fixedTime);
      } else if (args.length === 1) {
        super(args[0] as string | number | Date);
      } else {
        const [year, month, date, hours, minutes, seconds, ms] = args as [
          number,
          number,
          number?,
          number?,
          number?,
          number?,
          number?,
        ];
        super(year, month, date, hours, minutes, seconds, ms);
      }
    }

    static now() {
      return fixedTime;
    }
  } as DateConstructor;

  try {
    return operation();
  } finally {
    globalThis.Date = RealDate;
  }
}
