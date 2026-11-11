// l10n-allow-file: gallery and test fixtures (public-safe sample chats), not shipped UI.
// Sample chat history blocks at the sidebar's Standard density (SidebarLayoutMetrics.standard and
// SidebarStyle at the default sizes), for the gallery, the browser dev loop and the tests.
import type { SidebarChatRow, SidebarChatsBlock, SidebarChatsMetrics, SidebarChatsStrings } from "./model";

export const FIXTURE_METRICS: SidebarChatsMetrics = {
  header: 28,
  row: 28,
  spacing: 2,
  radius: 6,
  iconX: 8,
  iconBox: 16,
  glyph: 14,
  textX: 32,
  plainTextX: 12,
  headerX: 8,
  edge: 8,
  headerEnd: 36,
  chevronEnd: 10,
  chevron: 12,
  titleSize: 13,
  metaSize: 11,
  headerSize: 11,
};

export const FIXTURE_STRINGS: SidebarChatsStrings = {
  pinned: "Pinned",
  earlier: "Earlier",
  showMore: "Show More",
  loading: "Loading chats…",
};

const TITLES = [
  "Fix the omnibar focus ring",
  "Release notes for the nightly",
  "Why does the sidebar jump on relaunch",
  "Port the bookmarks bar",
  "Review the group editor",
  "Draft the onboarding copy",
  "Trace the scroll hitch",
  "Split the settings schema",
];
const AGES = ["2m", "14m", "1h", "3h", "5h", "1d", "2d", "6d"];
const HARNESSES = ["claude-code", "codex"];

/** `count` chats, newest first; every fifth one from a harness no mark knows, whose mark takes a theme colour
 * (the host sends its group colour as CSS). */
export function fixtureRows(count: number, offset = 0): SidebarChatRow[] {
  return Array.from({ length: count }, (_, index) => {
    const n = index + offset;
    const unknown = n % 5 === 4;
    return {
      id: `chat-${n}`,
      title: TITLES[n % TITLES.length]!,
      meta: AGES[Math.min(n, AGES.length - 1)]!,
      harness: unknown ? "acme-agent" : HARNESSES[n % 2]!,
      markColor: unknown ? "var(--cmux-app-success)" : null,
    };
  });
}

export function fixtureBlock(overrides: Partial<SidebarChatsBlock> = {}): SidebarChatsBlock {
  return {
    revision: 1,
    part: "earlier",
    folded: false,
    rows: fixtureRows(3),
    tail: "more",
    metrics: FIXTURE_METRICS,
    ...overrides,
  };
}
