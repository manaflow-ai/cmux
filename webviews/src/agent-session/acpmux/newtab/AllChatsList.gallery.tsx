// l10n-allow-file: gallery fixtures use sample chat rows and a deterministic page cursor.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { ComponentProps } from "react";
import { AllChatsList, type AllChatsPage, type LoadChatsPage } from "./AllChatsList";

const rows = Array.from({ length: 8 }, (_, index) => ({
  key: `claude:gallery-${index}`,
  harness: "claude",
  title: index === 0 ? "Recover a failed history page" : `Earlier chat ${index}`,
  cwd: "/Users/you/src/cmux",
  updatedAt: Date.now() - index * 60_000,
}));

const first: AllChatsPage = { chats: rows, nextCursor: "page-2", ready: true, design: "age" };
const second: AllChatsPage = {
  chats: [
    {
      key: "claude:gallery-older",
      harness: "claude",
      title: "An older recovered chat",
      cwd: "/Users/you/src/cmux",
      updatedAt: Date.now() - 12 * 60_000,
    },
  ],
  ready: true,
};

const baseProps = {
  onOpen: () => undefined,
  onOpenInTerminal: () => undefined,
};

const waitForRetry = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-chats-retry") !== null);
};

const pageLoad =
  (failed: boolean): LoadChatsPage =>
  async ({ cursor }) => {
    if (!cursor) return first;
    return failed ? undefined : second;
  };

// Long titles and folders cut at the row's edge, and carry their whole value as a tooltip, the
// live chats at the top included; ages from a week on read as a date (#28079).
const DAY_MINUTES = 24 * 60;
const LONG_CWD = "/Users/sample/projects/atlas-web-payments-reconciliation-service";
const longRows: AllChatsPage = {
  chats: [
    {
      key: "claude:long-recent",
      harness: "claude",
      title: "Reconcile the payment ledger against the processor export before the quarterly close",
      cwd: LONG_CWD,
      updatedAt: minutesAgo(3 * 60),
    },
    {
      key: "codex:long-week",
      harness: "codex",
      title: "Tidy the retry policy",
      cwd: LONG_CWD,
      updatedAt: minutesAgo(6 * DAY_MINUTES),
    },
    {
      key: "claude:long-older",
      harness: "claude",
      title: "Make the reconciliation worker retry with backoff so a dropped connection never double-charges",
      cwd: LONG_CWD,
      updatedAt: minutesAgo(9 * DAY_MINUTES),
    },
    {
      key: "claude:long-months",
      harness: "claude",
      title: "Audit the invoice exports",
      cwd: "/Users/sample/projects/atlas-web",
      updatedAt: minutesAgo(95 * DAY_MINUTES),
    },
  ],
  ready: true,
  design: "project",
};
const longActive = [
  {
    id: "gallery-live-long",
    title: "Migrate every merchant's saved payment methods to the new vault without a re-prompt",
    harness: "claude",
    state: "running" as const,
    label: "Working",
  },
  { id: "gallery-live-short", title: "Release notes", harness: "codex", state: "input" as const, label: "Needs input" },
];

export default componentEntry<ComponentProps<typeof AllChatsList>>({
  id: "agent-pane.all-chats-list",
  title: "All chats page recovery",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./AllChatsList").then((module) => module.AllChatsList),
  widths: { narrow: 420, normal: 620, wide: 820 },
  height: 360,
  anchors: [{ selector: ".nt-all" }],
  variants: {
    "page-failed": {
      note: "When an older history page fails, the cursor stays in place and the loader becomes an inline Try again action.",
      props: { ...baseProps, load: pageLoad(true) },
      play: waitForRetry,
    },
    "page-recovered": {
      note: "Retrying the same older page appends its chats and removes the recovery row.",
      props: { ...baseProps, load: pageLoad(false) },
    },
    "long-values": {
      note: "Long titles and folders cut at the row's edge and carry their whole value as a tooltip, the live chats at the top included; ages from a week on read as a date.",
      props: { ...baseProps, load: async () => longRows, active: longActive, now: GALLERY_NOW },
    },
    "page-empty": {
      note: "A first page with no cursor stays a quiet list with no dead loader row.",
      props: { ...baseProps, load: async () => ({ chats: rows, ready: true }) },
    },
  },
});
