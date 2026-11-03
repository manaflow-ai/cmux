// l10n-allow-file: assertions use the localized builder output, not shipped copy.
import { expect, test } from "bun:test";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { usageSection } from "../src/agent-session/acpmux/session-info/native/usage";
import type { SessionUsageStats } from "../src/agent-session/acpmux/usageStats";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const t: Translate = (key, values) => translate(key, values, "en");
const stats = (overrides: Partial<SessionUsageStats> = {}): SessionUsageStats => ({
  autocompact: "unknown",
  updatedAt: 1,
  ...overrides,
});
const session = (
  sessionId: string,
  usageStats: SessionUsageStats,
  extra: Partial<AcpmuxSessionEntry> = {},
): AcpmuxSessionEntry => ({
  sessionId,
  usageStats,
  title: sessionId,
  ...extra,
});

test("usage keeps the token fallback and disabled restart-with-cap affordance", () => {
  const own = stats({ tokens24h: 1200, autocompact: "none" });
  const section = usageSection({ own, sessions: [], open: true }, new NativeInfoActions(), t)!;
  expect(section.meta).toBe(t("sessionInfo.usage.tokens24hValue", { tokens: "1.2K" }));
  const cap = section.rows.find((row) => row.id === "own:cap")!;
  expect(cap.trailing).toBe(t("sessionInfo.usage.noCap"));
  expect(cap.buttons?.[0]?.disabled).toBe(true);
  expect(cap.help).toBe(t("sessionInfo.usage.restartWithCapSoon"));
});

test("usage shows the prompt cache's read share and cost per call, as the web panel does", () => {
  const own = stats({ cacheReadShare24h: 0.981, costPerCallUsd24h: 0.3363 });
  const section = usageSection({ own, sessions: [], open: true }, new NativeInfoActions(), t)!;
  const trailing = (id: string) => section.rows.find((row) => row.id === id)?.trailing;
  expect([trailing("own:cache-read"), trailing("own:call-cost")]).toEqual(["98.1%", "$0.34"]);
});

test("usage preserves harness marks, ranks sessions, and exposes sort and View all actions", async () => {
  const sessions = Array.from({ length: 6 }, (_, index) =>
    session(`s${index}`, stats({ costUsd24h: index + 1, contextTokens: (index + 1) * 100 }), {
      harness: index === 5 ? "claude" : undefined,
      host: index === 0 ? "cmux" : undefined,
    }),
  );
  let nextSort: string | undefined;
  let expanded: boolean | undefined;
  const section = usageSection(
    {
      sessions,
      open: true,
      sort: "cost",
      onSortChange: (sort) => {
        nextSort = sort;
      },
      onExpandedChange: (value) => {
        expanded = value;
      },
    },
    new NativeInfoActions(),
    t,
  )!;
  expect(section.rows.find((row) => row.id === "session:s5")?.trailing).toBe("$6.00");
  expect(section.rows.find((row) => row.id === "session:s5")?.harness).toBe("claude");
  const sort = section.rows.find((row) => row.id === "sort")!;
  expect(sort.buttons).toHaveLength(2);
  const actions = new NativeInfoActions();
  // Rebuild with a shared actions object to exercise the page-owned callbacks.
  const rebuilt = usageSection(
    {
      sessions,
      open: true,
      sort: "cost",
      onSortChange: (value) => {
        nextSort = value;
      },
      onExpandedChange: (value) => {
        expanded = value;
      },
    },
    actions,
    t,
  )!;
  expect(actions.run(rebuilt.rows.find((row) => row.id === "sort")!.buttons![1]!.action)).toBe(true);
  await Promise.resolve();
  expect(nextSort).toBe("context");
  expect(rebuilt.more).toBeDefined();
  expect(actions.run(rebuilt.more!.action)).toBe(true);
  await Promise.resolve();
  expect(expanded).toBe(true);
});

test("a folded usage section stays present without ranking until it opens", () => {
  const sessions = [session("s1", stats({ costUsd24h: 1 }))];
  const section = usageSection({ sessions, hasSessionUsage: true, open: false }, new NativeInfoActions(), t)!;
  expect(section).toBeDefined();
  expect(section.rows).toEqual([]);
});
