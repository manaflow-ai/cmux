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

/// acpmux's end of a background command (hub/bg_notify.rs): sender `acpmux`, severity from the exit
/// alone, title `Background command finished: COMMAND (exit N)` (the command one line, cut to 120
/// characters), body the task and its output's last lines. Leo, 2026-11-08: "why was there a yellow
/// warning symbol? ... why is there only ACPMux as a bare thing".
type BgEnd = { task: string; command: string; exit: number; output: string };
const OK_REMOTE: BgEnd = {
  task: "bg-b08e9de42d3e",
  command:
    "cmux-ci test --committed --timeout 1500 -- 'cd tools/fleet-reconcilers && python3 -m unittest test_now 2>&1 | tail -25'",
  exit: 0,
  output:
    "cmux-ci test: admitted eefe60e4 on linux-pool-4; no-start reroute remains 180s\nremote:\nremote: Create a pull request for 'fast-checks/50232cb1' on GitHub by visiting:\nremote:\nwarning: 1 test skipped\nOK",
};
const FAILED: BgEnd = {
  task: "bg-7c1d",
  command: "cargo test -p acpmux bg_notify",
  exit: 101,
  output: "test result: FAILED. 3 passed; 1 failed",
};
const LONG_WT: BgEnd = {
  task: "bg-2d90135420b2",
  command:
    "wt new manaflow-ai/cmux lane/summary-sources-screenshot-labels --topic 'summary card Sources screenshot labels' --files…",
  exit: 0,
  output:
    "note: webviews/src/agent-session/acpmux/summary changed more often on feat-cmux-next in the window than one page holds",
};
const MULTI_LINE: BgEnd = {
  task: "bg-9a01",
  command: "make \\\n  lint \\\n  test",
  exit: 0,
  output: "lint: ok\ntest: 412 passed",
};

function bgText(end: BgEnd): string {
  const title = bgTitle(end);
  const tag = end.exit === 0 ? "" : " · WARN";
  return `[notice from acpmux${tag}] ${title}\nTask ${end.task}: ${end.command.replace(/\s+/g, " ")}\nLast ${end.output.split("\n").length} lines of its output:\n${end.output}\n(bg_output reads all of it.)`;
}
const bgTitle = (end: BgEnd) => `Background command finished: ${end.command.replace(/\s+/g, " ")} (exit ${end.exit})`;
const bgProvenance = (end: BgEnd) => ({
  kind: "notice",
  from: "fromAgent",
  fromName: "acpmux",
  to: SESSION_ID,
  notice: { sender: "acpmux", severity: end.exit === 0 ? "info" : "warn", title: bgTitle(end) },
  bgTaskId: end.task,
});

/// A row as direct.ts keeps it: a notice's row text, else the prompt's.
function received(raw: string, meta: Record<string, unknown>, minutes: number) {
  const incoming = incomingPrompt(raw, { client: "acpmux#bg", _meta: { provenance: meta } });
  if (incoming?.kind !== "message") return user(raw, minutes);
  const { message } = incoming;
  return user(message.notice ? noticeRowText(message.notice, message.text) : message.text, minutes, {
    incoming,
    untyped: true,
    resend: raw,
  });
}

/// Ends that waited behind a busy turn go in as one (hub/digest.rs `digest_blocks`).
function bgDigest(ends: readonly BgEnd[], minutes: number) {
  const parts = ends.map(
    (end, i) => `${i ? "\n\n" : ""}[agent message ${i + 1} of ${ends.length}] from acpmux\n${bgText(end)}`,
  );
  const raw = `${ends.length} messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.\n\n${parts.join("")}`;
  const messages = ends.map((end) => ({
    promptId: `bg-done-${end.task}`,
    from: "acpmux",
    provenance: bgProvenance(end),
  }));
  return received(raw, { kind: "agent_digest", messages }, minutes);
}

/// One of each: a success whose output has `remote:` and `warning:` lines, a failure, a long `wt new`,
/// a command written over several lines, then two that went in together.
function background() {
  const turn = (text: string, at: number) => [
    assistant(text, at),
    summary(at - 0.1, { status: "completed", durationMs: 2_000, toolCount: 0 }),
  ];
  return chat(
    [
      ...opening,
      received(bgText(OK_REMOTE), bgProvenance(OK_REMOTE), 25),
      ...turn("The reconciler tests pass.", 24.8),
      received(bgText(FAILED), bgProvenance(FAILED), 20),
      ...turn("One bg_notify test fails; reading it.", 19.8),
      received(bgText(LONG_WT), bgProvenance(LONG_WT), 15),
      ...turn("The worktree is ready.", 14.8),
      received(bgText(MULTI_LINE), bgProvenance(MULTI_LINE), 10),
      ...turn("Lint and tests pass.", 9.8),
      bgDigest([LONG_WT, OK_REMOTE], 5),
      ...turn("Both finished.", 4.8),
    ],
    { title: "coordinator", sessions },
  );
}

/// Opens the two ends that went in together.
const openDigest: Play = async (ctx) => {
  const lines = () => [...ctx.document.querySelectorAll(".cv-received .cv-disclosure__toggle")];
  await ctx.waitFor(() => lines().length >= 5 || null, { capMs: 10_000 });
  const last = lines().at(-1)!;
  if (last.getAttribute("aria-expanded") !== "true") (last as HTMLElement).click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__text"), { capMs: 10_000 });
};

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
  "single-hover": {
    note: "A notice's line under the pointer: its title lights all the way through, as a tool row's words do (Leo, 2026-11-09).",
    snapshot: single(),
    play: async (ctx) => ctx.hover({ selector: ".cv-disclosure__toggle:not(.is-chevron) .cv-notice__lead" }),
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
  background: {
    note: "Background command ends (acpmux hub/bg_notify.rs): exit 0 with remote:/warning: output reads info; exit 101 warns; a long wt new and a multi-line command keep (exit N) on the line; two that went in together read as one notice +1, never acpmux · acpmux.",
    snapshot: background(),
  },
  "background-digest-open": {
    note: "The two ends that went in together, opened: each under its own title, no [notice from …] head.",
    snapshot: background(),
    play: openDigest,
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
