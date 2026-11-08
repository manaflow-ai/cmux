// l10n-allow-file: gallery fixtures (sample tool names, hosts and pages), not shipped UI.
// A tool's or reconciler's notice to a chat (manaflow-ai/cmuxterm-hq#6380; agentNotice.ts): a base-red
// watch's FIRE, an autoland's LANDED, a queue warning. Leo, 2026-11-03, on such a page drawn as a raw
// user bubble: "acpmux/cmux-next should be able to allow you guys to make (and subsequently nicely
// render) this sort of thing". Each draws as one received line (IncomingMessageCard.tsx): the
// severity's mark in the tool rows' icon column, the sender and its machine, the title; opened, the
// body and its links (`#32827`, `run 1902234…`), never the rendered head or the Links line. Several
// in a row fold into "Received N notices", whose head shows a fire when one is in it. `before` is
// the page as the pane drew it. The `look-*` versions beside the default are noticeLook.ts's
// (`theme.noticeLook`). Names, hosts and numbers are made up.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";
import { noticeRowText } from "./agentNotice";

type Page = {
  sender: string;
  host?: string;
  severity: "info" | "warn" | "fire";
  title: string;
  body: string;
  links: { url: string; label?: string }[];
};

const FIRE: Page = {
  sender: "base-red-watch",
  host: "ci-mini-3",
  severity: "fire",
  title: "cmux-next fast tier failed on 3 PRs since 02:07Z",
  body: "Failed steps: **Run the fast tier** on #32801, #32815 and #32827.\n\nOwner: the coordinator (fallback). Check it against base and land the fix first.",
  links: [
    { url: "https://github.com/manaflow-ai/cmux/pull/32827", label: "#32827" },
    { url: "https://github.com/manaflow-ai/cmux/actions/runs/19022341987" },
  ],
};
const LANDED: Page = {
  sender: "next-autoland",
  host: "lane-box-2",
  severity: "info",
  title: "Landed #32790 as 4f1c2a9",
  body: "Squash-merged at the reviewed head; the nightly picks it up at the next cut.",
  links: [{ url: "https://github.com/manaflow-ai/cmux/pull/32790" }],
};
const WARN: Page = {
  sender: "queue-janitor",
  host: "ci-mini-7",
  severity: "warn",
  title: "macOS compile queue is 40 min deep",
  body: "6 jobs wait on `macos-compile`; two minis are offline. Overflow starts in 3 min unless one comes back.",
  links: [{ url: "https://fleet.example.com/queue/macos-compile", label: "Queue" }],
};

/// The prompt's text as `acpmux send --notice` renders it.
function rendered(page: Page): string {
  const tag = page.severity === "info" ? "" : ` · ${page.severity.toUpperCase()}`;
  const host = page.host ? ` on ${page.host}` : "";
  const links = page.links.map((link) => (link.label ? `${link.url} (${link.label})` : link.url)).join(", ");
  return [
    `[notice from ${page.sender}${host}${tag}] ${page.title}`,
    page.body,
    ...(links ? [`Links: ${links}`] : []),
  ].join("\n");
}

/// A notice as acpmux records it (provenance kind `notice`), read as direct.ts reads it.
function notice(page: Page, minutes: number) {
  const { sender, host, severity, title, links } = page;
  const raw = rendered(page);
  const incoming = incomingPrompt(raw, {
    client: "acpmux-cli#01a2f3",
    _meta: {
      provenance: {
        kind: "notice",
        from: "fromAgent",
        fromName: sender,
        to: SESSION_ID,
        notice: { sender, ...(host && { host }), severity, title, links },
      },
    },
  });
  return incoming?.kind === "message" && incoming.message.notice
    ? user(noticeRowText(incoming.message.notice, incoming.message.text), minutes, {
        incoming,
        untyped: true,
        resend: raw,
      })
    : user(raw, minutes);
}

const sessions = [session({ sessionId: SESSION_ID, title: "coordinator", name: "coordinator" })];
const opening = [
  user("Watch base and the queue; land fixes for anything red.", 30),
  assistant("Watching base, the fast tier and the compile queue.", 29.8),
  summary(29.7, { status: "completed", durationMs: 9_000, toolCount: 0 }),
];

/// The three pages, each in its own turn, the FIRE newest.
function single() {
  return chat(
    [
      ...opening,
      notice(LANDED, 20),
      assistant("Noted; #32790 is in.", 19.9),
      summary(19.8, { status: "completed", durationMs: 3_000, toolCount: 0 }),
      notice(WARN, 12),
      assistant("I'll check the two offline minis.", 11.9),
      summary(11.8, { status: "completed", durationMs: 4_000, toolCount: 0 }),
      notice(FIRE, 6),
      assistant("Looking at the fast tier failure on #32827 first.", 5.8),
      summary(5.7, { status: "completed", durationMs: 14_000, toolCount: 0 }),
    ],
    { title: "coordinator", sessions },
  );
}

/// Three pages that arrived together: one row, "Received 3 notices", the fire on its head.
function folded() {
  return chat(
    [
      ...opening,
      notice(LANDED, 12),
      notice(FIRE, 11.5),
      notice(WARN, 11),
      assistant("The fast tier failure comes first; then the queue.", 10.8),
      summary(10.7, { status: "completed", durationMs: 6_000, toolCount: 0 }),
    ],
    { title: "coordinator", sessions },
  );
}

/// Before: the page as tell-coordinator sends it today, drawn as the person's own bubble.
function before() {
  const page =
    "[tell-coordinator from base-red-watch on ci-mini-3] FIRE cmux-next fast tier failed on 3 PRs (#32801, #32815, #32827) since 02:07Z. Failed steps: Run the fast tier. Owner: the coordinator (coordinator fallback). Check it against base and land the fix first.";
  return chat(
    [
      ...opening,
      user(page, 20),
      assistant("Looking at the fast tier failure on #32827 first.", 19.8),
      summary(19.7, { status: "completed", durationMs: 14_000, toolCount: 0 }),
    ],
    { title: "coordinator", sessions },
  );
}

/// Today's tell-coordinator page through `acpmux send` at a shell: read as a notice from its head.
function legacy() {
  const page =
    "[tell-coordinator from base-red-watch on ci-mini-3] FIRE cmux-next fast tier failed on 3 PRs (#32801, #32815, #32827) since 02:07Z. Failed steps: Run the fast tier. Owner: the coordinator (coordinator fallback). Check it against base and land the fix first.";
  const incoming = incomingPrompt(page, { client: "acpmux-outbox#01a16e@ci-mini-3" });
  return chat(
    [
      ...opening,
      incoming?.kind === "message" && incoming.message.notice
        ? user(noticeRowText(incoming.message.notice, incoming.message.text), 20, {
            incoming,
            untyped: true,
            resend: page,
          })
        : user(page, 20),
      assistant("Looking at the fast tier failure on #32827 first.", 19.8),
      summary(19.7, { status: "completed", durationMs: 14_000, toolCount: 0 }),
    ],
    { title: "coordinator", sessions },
  );
}

const LINE = ".cv-received.cv-notice.is-fire .cv-disclosure__toggle";
const HEAD = ".cv-lane-batch[data-kind='inbox'] .cv-lane-batch__toggle";

/// Opens the FIRE's line.
const openFire: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(LINE), { capMs: 10_000 });
  if (ctx.document.querySelector(LINE)?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-notice.is-fire .cv-received__text"), { capMs: 10_000 });
};

/// Opens the fold, then its fire.
const openFold: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(HEAD), { capMs: 10_000 });
  if (ctx.document.querySelector(HEAD)?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: HEAD });
  const fire = ".cv-lane-batch__body .cv-notice.is-fire .cv-disclosure__toggle";
  await ctx.waitFor(() => ctx.document.querySelector(fire), { capMs: 10_000 });
  await ctx.click({ selector: fire });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-notice.is-fire .cv-received__text"), { capMs: 10_000 });
};

const variants: Record<string, AgentPaneVariant> = {
  single: {
    note: "Selected default (look mark): a LANDED, a WARN and a FIRE, each its own line: the severity's mark in the icon column (red disc, quiet ring, amber triangle), the sender and its machine, the title.",
    snapshot: single(),
  },
  "single-open": {
    note: "The FIRE opened: its body as Markdown, then its links named as chips name them; no [notice from …] head, no Links: line.",
    snapshot: single(),
    play: openFire,
  },
  fold: {
    note: 'Three notices that arrived together: one row, "Received 3 notices", the fire\'s mark on its head.',
    snapshot: folded(),
  },
  "fold-open": {
    note: "The fold opened, its FIRE opened.",
    snapshot: folded(),
    play: openFold,
  },
  "look-tag": {
    note: "Gallery version (theme noticeLook tag): the sender's agent mark in the icon column, the severity as a small word before the title.",
    theme: { noticeLook: "tag" },
    snapshot: single(),
  },
  "look-tint": {
    note: "Gallery version (theme noticeLook tint): the default line with a fire's or warning's title in its colour.",
    theme: { noticeLook: "tint" },
    snapshot: single(),
  },
  "look-tag-fold": {
    note: "Gallery version (theme noticeLook tag), the fold opened.",
    theme: { noticeLook: "tag" },
    snapshot: folded(),
    play: openFold,
  },
  legacy: {
    note: "Today's tell-coordinator page (a FIRE through acpmux send at a shell), read as a notice from its head.",
    snapshot: legacy(),
  },
  before: {
    note: "Before: the same page as the pane drew it, the person's own bubble.",
    snapshot: before(),
  },
};

export default agentPaneEntry({
  id: "agent-pane.notice-row",
  title: "Notice row",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/agentNotice.ts",
    "agent-session/acpmux/conversation/NoticeMark.tsx",
    "agent-session/acpmux/conversation/NoticeMark.css",
    "agent-session/acpmux/conversation/noticeLook.ts",
  ],
  variants,
});
