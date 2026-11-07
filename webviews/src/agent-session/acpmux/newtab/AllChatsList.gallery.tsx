// l10n-allow-file: gallery fixtures use sample chat rows and a deterministic page cursor.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { Play, PlayContext } from "../../../gallery/play";
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

// The leaders (leads.ts): every live chat other chats report to, once, above the live chats.
const leads = [
  { id: "gallery-lead-area", title: "area-owner", harness: "claude", state: "running" as const, label: "6 reporting" },
  { id: "gallery-lead-coord", title: "coordinator", harness: "claude", state: "idle" as const, label: "4 reporting" },
  { id: "gallery-lead-codex", title: "ui-owner", harness: "codex", state: "input" as const, label: "2 reporting" },
];

// Projects with chats in three folders, for the fold (listMotion.ts).
const PROJECT_DIRS = ["/Users/you/src/cmux", "/Users/you/src/uploader", "/Users/you/src/docs"];
const projectRows: AllChatsPage = {
  chats: Array.from({ length: 9 }, (_, index) => ({
    key: `claude:project-${index}`,
    harness: index % 3 === 1 ? "codex" : "claude",
    title: [
      "Fold sweep onto the settle",
      "Retry uploads with backoff",
      "Release notes for the nightly",
      "Sidebar rows on the grid",
      "Cover retry with tests",
      "Fix the docs index",
      "Composer hat polish",
      "Chunk large uploads",
      "Link the motion guide",
    ][index]!,
    cwd: PROJECT_DIRS[index % 3],
    updatedAt: minutesAgo(index * 7 + 1),
  })),
  ready: true,
  design: "age",
};

const PROJECTS_TAB = ".nt-chats-head > button.nt-chats-tab:nth-of-type(2)";
const FIRST_PROJECT = ".nt-all-item > button.nt-all-group";
const settled = (ctx: PlayContext) => ctx.document.getAnimations().length === 0;

const showProjects = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(PROJECTS_TAB));
  await ctx.click({ selector: PROJECTS_TAB });
  await ctx.waitFor(() => ctx.document.querySelector(FIRST_PROJECT));
};

/// The first project folds into its header and the projects under it rise; it ends exactly on the folded
/// list, with no ghost left drawn and nothing running.
const projectFolds: Play = async (ctx) => {
  await showProjects(ctx);
  await ctx.click({ selector: FIRST_PROJECT });
  await ctx.waitFor(() => settled(ctx), { capMs: 3000 });
  if (ctx.document.querySelector("[data-list-ghost]")) throw new Error("A folded chat is still drawn after the fold");
  if (ctx.find({ selector: FIRST_PROJECT }).getAttribute("aria-expanded") !== "false")
    throw new Error("The project did not fold");
};

/// The same fold held 60 ms in: the chats partway into the header, fading, the rows under it rising.
const projectMidFold: Play = async (ctx) => {
  await showProjects(ctx);
  await ctx.click({ selector: FIRST_PROJECT });
  await ctx.waitFor(() => ctx.document.getAnimations().length > 0);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 60;
  }
};

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
    leads: {
      note: "Leads: every leader (a live chat other chats report to) once, with how many report to it; a press opens its chat.",
      props: { ...baseProps, load: async () => longRows, active: longActive, leads, now: GALLERY_NOW },
    },
    "projects-open": {
      note: "Projects: the chats under their folders, every project open; each header's chevron points down.",
      props: { ...baseProps, load: async () => projectRows, now: GALLERY_NOW },
      play: showProjects,
    },
    "project-fold-settle": {
      note: 'Chosen. A project folds: its chats slide up into its header and fade while the projects under it rise into place, every row and the chevron on the settle (--cmux-ease-settle, cubic-bezier(0.16, 1, 0.3, 1) over 265 ms), fast at first and decelerating into the end, never past it; nothing is drawn after it ends (Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key").',
      props: { ...baseProps, load: async () => projectRows, now: GALLERY_NOW },
      play: projectFolds,
    },
    "project-mid-fold": {
      note: "The same fold held 60 ms in: most of the way there already, on the settle's long soft tail.",
      props: { ...baseProps, load: async () => projectRows, now: GALLERY_NOW },
      play: projectMidFold,
    },
    "page-empty": {
      note: "A first page with no cursor stays a quiet list with no dead loader row.",
      props: { ...baseProps, load: async () => ({ chats: rows, ready: true }) },
    },
  },
});
