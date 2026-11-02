// l10n-allow-file: gallery fixtures (sample lane messages), not shipped UI.
// Other sessions' messages as Claude Code draws them (Leo, 2026-10-29: "why the fuck did you guys
// ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE" / "AND IT'S SO FUCKING
// AWKWARD TO SEE THEM THERE AT THE BOTTOM SINCE WHEN I EXPAND THEM IT JUMPS ME DOWN AND WHEN I
// COLLAPSE IT JUMPS ME UP" / "LOOK AT THESE / LEARN FROM CLAUDE CODE"): each message is one quiet
// disclosure line where it arrived (IncomingMessageCard.tsx on the shared DisclosureRow), never a
// card cut short and never one card of them all at the bottom. Delivered ones sit between the
// replies they came between, a steer the agent has not read sits in the running turn with "Read
// after this step" as a small tag at its line's end, and one queued behind the turn sits after it
// under one "Read after this turn" said over the first of the queued messages. The line opens the whole message under it, the line holding still.
// The line's look: A, the sender then the message's first line muted, ships; B (Claude Code's
// "Received a message from" wording, no preview), C (A plus how many more lines) and D (the sender
// alone) are drawn here only, over the shipped line.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const incoming = (name: string, text: string, sessionId: string) => ({
  incoming: { kind: "message" as const, message: { name, text, raw: text, sessionId } },
  untyped: true,
});

const DEP_FLEET =
  "**dep-fleet**: rolled the runner agent 0.48 to all 14 build boxes.\n\nbuild-box-6 and build-box-9 needed a runner restart; both are back and took jobs within a minute.\n\nNothing needs you.";
const FANOUT = [
  "**Landing report** for fanout-infra:",
  "",
  "- #27104 merged; the picker now fails over a stalled label after 3 minutes.",
  "- #27118 is in review; its only red is the gallery scope menu, red on base too.",
  "- #27121 waits on #27118 to rebase.",
  "",
  "| job | before | after |",
  "|---|---:|---:|",
  "| queue p95 | 7m 40s | 41s |",
  "| compile p50 | 6m 02s | 5m 48s |",
  "",
  "Next: the Chromium cross-build moves to Linux. I'll report when #27118 lands.",
].join("\n");
const SIDEBAR = "nx-sidebar: the row hover covers only the PR button now (#27130), screenshots in the PR.";
const IOS = "ios-remote: TestFlight 412 is up with the reconnect fix; two testers confirmed it.";
const ARTIFACTS = "artifacts: R2 retention is 30 days; 1.2 TB cleared.";

const snapshot = chat(
  [
    user("Fan the fleet work out and report back here", 9),
    assistant("Started dep-fleet, fanout-infra and nx-sidebar; they will message this chat.", 8.8),
    summary(8.8, { status: "completed" }),
    user(DEP_FLEET, 8, incoming("dep-fleet", DEP_FLEET, "s-dep")),
    user(FANOUT, 7.6, incoming("claude-sr2/fanout-infra", FANOUT, "s-fanout")),
    user(SIDEBAR, 7.2, incoming("nx-sidebar", SIDEBAR, "s-sidebar")),
    assistant("Noted. Rebasing the picker change onto #27104.", 6.8),
    summary(6.8, { status: "completed" }),
    user("Now land #27118 once it is green", 2),
    user(IOS, 1.5, { ...incoming("ios-remote", IOS, "s-ios"), steer: "waiting", steerPromptId: "steer-1" }),
    assistant("Checking #27118's reds against base…", 0.5, { streaming: true }),
  ],
  {
    isWorking: true,
    queue: [
      {
        id: "q1",
        prompt: ARTIFACTS,
        message: { name: "artifacts", sessionId: "s-art", text: ARTIFACTS, raw: ARTIFACTS },
      },
    ],
  },
);

/// Opens the group of messages that wait (ios-remote's steer, artifacts' queued one), which shows
/// collapsed after the turn, so all five lines show.
const openWaiting: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-pending__toggle"));
  if (ctx.document.querySelector('.cv-pending__toggle[aria-expanded="false"]'))
    ctx.document.querySelector<HTMLButtonElement>(".cv-pending__toggle")!.click();
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-received").length >= 5);
};

/// Opens the fanout-infra report, the long one with a table.
const openReport: Play = async (ctx) => {
  await openWaiting(ctx);
  const line = [...ctx.document.querySelectorAll<HTMLElement>(".cv-received")].find((row) =>
    row.querySelector(".cv-received__from")?.textContent?.includes("fanout-infra"),
  );
  line?.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__text table") !== null);
};

const ALT_ID = "incoming-disclosure-alt";
/// Draws a gallery-only line over the shipped one: its stylesheet, then `mark` on each line.
const alternate =
  (css: string, mark: (line: HTMLElement) => void): Play =>
  async (ctx) => {
    await openWaiting(ctx);
    ctx.document.getElementById(ALT_ID)?.remove();
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = css;
    ctx.document.head.append(style);
    ctx.document.querySelectorAll<HTMLElement>(".cv-received").forEach(mark);
  };
/// B: Claude Code's wording, "Received a message from <name>", and no preview.
const received = alternate(
  `.cv-received__preview { display: none; }
.cv-received__said { color: var(--cv-text-dim); flex: none; }`,
  (line) => {
    const from = line.querySelector(".cv-received__from");
    if (!from || from.previousElementSibling?.classList.contains("cv-received__said")) return;
    const said = line.ownerDocument.createElement("span");
    said.className = "cv-received__said";
    said.textContent = "Received a message from";
    from.before(said);
  },
);
/// C: A, then how many more lines the message has.
const counted = alternate(
  `.cv-received__count { flex: none; color: var(--cv-text-dim); font-size: var(--text-caption); opacity: 0.8; }`,
  (line) => {
    const preview = line.querySelector(".cv-received__preview");
    const name = line.querySelector(".cv-received__from")?.textContent ?? "";
    const text = [DEP_FLEET, FANOUT, SIDEBAR, IOS, ARTIFACTS].find((body) =>
      body.toLowerCase().includes(name.split("/").pop()!.toLowerCase()),
    );
    const more = (text ?? "").split("\n").filter((part) => part.trim()).length - 1;
    if (!preview || more < 1 || preview.nextElementSibling?.classList.contains("cv-received__count")) return;
    const count = line.ownerDocument.createElement("span");
    count.className = "cv-received__count";
    count.textContent = `+${more} lines`;
    preview.after(count);
  },
);
/// D: the sender alone; the message only once opened.
const senderOnly = alternate(`.cv-received__preview { display: none; }`, () => undefined);

export default agentPaneEntry({
  id: "agent-pane.incoming-message-disclosure",
  title: "Other sessions' messages, one line each",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
    "agent-session/acpmux/subagents/DisclosureRow.tsx",
  ],
  variants: {
    "a-shipped": {
      note: "A (ships): each delivered message is one line where it arrived: the sender, then its first line muted, then ›. Three delivered between the replies; ios-remote's unread steer and artifacts' queued message wait in one collapsed group after the turn, no Read after this turn. Nothing cut without a way to open it.",
      snapshot,
    },
    "a-shipped-open": {
      note: "A, fanout-infra's report opened: the whole message as Markdown, its table and all, wrapped and never cut. Its line did not move; the panel grew under it.",
      snapshot,
      play: openReport,
    },
    "b-received-wording": {
      note: 'B (gallery only): Claude Code\'s wording, "Received a message from <name>", with no preview. Reads closest to Claude Code but says less per line.',
      snapshot,
      play: received,
    },
    "c-line-count": {
      note: "C (gallery only): A plus how many more lines follow. Useful, but the count competes with the tag for the line's end.",
      snapshot,
      play: counted,
    },
    "d-sender-only": {
      note: "D (gallery only): the sender alone; the message shows only once opened. The quietest, but the reader can't tell which message matters without opening each.",
      snapshot,
      play: senderOnly,
    },
  },
});
