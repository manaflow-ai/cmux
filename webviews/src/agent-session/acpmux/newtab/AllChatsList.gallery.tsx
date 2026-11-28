// l10n-allow-file: gallery fixtures use sample chat rows and a deterministic page cursor.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { ComponentProps } from "react";
import { AllChatsList } from "./AllChatsList";
import { type AllChatsPage, type LoadChatsPage } from "./allChatsListModel";

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

// The stage's zero grace (lasting.ts setLastingGrace) shows the quiet line at once.
const waitForStillLoading = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-all-item.nt-chats-failed") !== null);
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

// When and the search's operators (ask-b75ea23533): a stand-in for acpmux that reads `since:Nd`
// and `harness:` as chats/terms.rs does, so the list narrows as it would.
const operatorLoad: LoadChatsPage = async ({ query = "" }) => {
  const days = /(?:^|\s)since:(\d+)d(?:\s|$)/.exec(query)?.[1];
  const harness = /(?:^|\s)harness:(\S+)/.exec(query)?.[1];
  const since = days ? GALLERY_NOW - Number(days) * DAY_MINUTES * 60_000 : -Infinity;
  const chats = longRows.chats.filter((row) => row.updatedAt >= since && (!harness || row.harness.startsWith(harness)));
  return { ...longRows, chats };
};
const WHEN = { role: "button", name: "Last used" } as const;

// The leaders (leads.ts): every live chat other chats report to, once, above the live chats.
const leads = [
  { id: "gallery-lead-area", title: "area-owner", harness: "claude", state: "running" as const, label: "6 reporting" },
  { id: "gallery-lead-coord", title: "coordinator", harness: "claude", state: "idle" as const, label: "4 reporting" },
  { id: "gallery-lead-codex", title: "ui-owner", harness: "codex", state: "input" as const, label: "2 reporting" },
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
      note: "When an older history page keeps failing, the cursor stays in place and the list asks again on its own; past the deadline the loader becomes one quiet line, with no button.",
      props: { ...baseProps, load: pageLoad(true) },
      play: waitForStillLoading,
    },
    "page-recovered": {
      note: "An older page that answers (as an ask again does once the daemon is back) appends its chats with no recovery row.",
      props: { ...baseProps, load: pageLoad(false) },
    },
    "long-values": {
      note: "Long titles and folders cut at the row's edge and carry their whole value as a tooltip, the live chats at the top included; ages from a week on read as a date.",
      props: { ...baseProps, load: async () => longRows, active: longActive, now: GALLERY_NOW },
    },
    leads: {
      note: "Leads: every leader (a live chat other chats report to) once, with how many report to it; a press opens its chat.",
      props: { ...baseProps, load: async () => longRows, active: longActive, leads, now: GALLERY_NOW },
    },
    "when-menu": {
      note: "When, beside Filter: Any time, Past day, Past week or Past month, Any time checked.",
      props: { ...baseProps, load: operatorLoad, active: longActive, now: GALLERY_NOW },
      play: async (ctx) => {
        await ctx.click(WHEN);
        await ctx.waitFor(() => ctx.document.querySelector("[role=menuitemradio]"));
      },
    },
    "when-past-week": {
      note: "Past week writes since:7d into the search: the chats from the last seven days stay, the live chats too (they are in use now).",
      props: { ...baseProps, load: operatorLoad, active: longActive, now: GALLERY_NOW },
      play: async (ctx) => {
        await ctx.click(WHEN);
        await ctx.click({ role: "menuitemradio", name: "Past week" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-all-item").length === 2);
      },
    },
    "operators-typed": {
      note: "Operators typed by hand: since:3d harness:claude narrows to Claude chats of the last three days; When names the since: as typed.",
      props: { ...baseProps, load: operatorLoad, active: longActive, now: GALLERY_NOW },
      play: async (ctx) => {
        await ctx.type("since:3d harness:claude", { selector: ".nt-all-search input" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-all-item").length === 1);
      },
    },
    "page-empty": {
      note: "A first page with no cursor stays a quiet list with no dead loader row.",
      props: { ...baseProps, load: async () => ({ chats: rows, ready: true }) },
    },
  },
});
