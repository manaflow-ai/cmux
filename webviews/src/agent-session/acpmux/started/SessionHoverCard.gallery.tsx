// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { sessionEntry } from "../sessionList";
import { type SessionHoverInfo, SessionHoverStore, hoverInfo } from "./sessionHover";
import { SessionHoverContent, SessionHoverContext } from "./SessionHoverCard";
import { StartedSessionChip } from "./StartedSessionCard";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import { IncomingMessageLine } from "../conversation/IncomingMessageCard";

type Props = { mode: "states" | "chip" | "reply" | "sender" };

const NOW = Date.now();
const MINUTE = 60_000;
/// One card for each kind of status line: a PR's status, needs input, failed, running, new activity, done.
const cards: SessionHoverInfo[] = [
  {
    sessionId: "c-1",
    title: "Switch gh-merge-green to merge-freeze issues",
    status: "failing",
    pullRequests: {
      count: 2,
      tone: "failing",
      number: 22092,
      repo: "cmux",
      others: [{ number: 22093, repo: "cmux" }],
    },
    preview: "Both PRs are open; CI fails on the merge-freeze fixture.",
    meta: ["cmux", "merge-freeze"],
    changedAt: NOW - 12 * MINUTE,
  },
  {
    sessionId: "c-2",
    title: "Bump the Ghostty pin",
    status: "merged",
    pullRequests: { count: 1, tone: "merged", number: 22164, repo: "cmux" },
    meta: ["cmux", "ghostty-pin"],
    changedAt: NOW - 3 * 60 * MINUTE,
  },
  {
    sessionId: "c-3",
    title: "Rename the settings keys",
    status: "waiting",
    waiting: { on: "permission" },
    meta: ["cmux", "settings-keys"],
    changedAt: NOW - 4 * MINUTE,
  },
  {
    sessionId: "c-4",
    title: "Fix the flaky sidebar test",
    status: "failed",
    pullRequests: { count: 1, tone: "failing", number: 22163, repo: "cmux" },
  },
  {
    sessionId: "c-5",
    title: "Draft the release notes",
    status: "running",
    doing: "Collect the merged PRs · gh pr list --state merged",
    meta: ["cmux", "Cloud: notes-box"],
    changedAt: NOW,
  },
  { sessionId: "c-6", title: "Triage the 10 failing Swift tests at the tip", status: "unread" },
  { sessionId: "c-7", title: "Read the theme after applyTheme", status: "done" },
];

const CHIP_ID = "01a0ebd5-0efe-721d-9edc-cf1a6ba78d98";
const chipEntry = sessionEntry({
  sessionId: CHIP_ID,
  title: "Switch gh-merge-green to merge-freeze issues",
  cwd: "/Users/you/Projects/cmux",
  branch: "merge-freeze",
  indicator: "working",
  status: "running",
  lane: { state: "working" },
  turn: { planStep: "Switch the merge check", activity: "Edit scripts/ci/gh_merge_green.py" },
  updatedAt: NOW - 2 * MINUTE,
  pullRequests: ["https://github.com/manaflow-ai/cmux/pull/22092"],
  pullRequest: { number: 22092, title: "Switch gh-merge-green", state: "open", checks: "failing" },
});
const store = new SessionHoverStore();
store.set([chipEntry]);
/// The sender variant: a lane's message whose name is a listed chat.
const subsessions = new SubsessionStore();
subsessions.set([
  sessionEntry({
    sessionId: CHIP_ID,
    name: "lane-host-2/merge-freeze",
    title: "Switch gh-merge-green to merge-freeze issues",
    harness: "claude",
  }),
]);

/// Each state's card as it shows over a reference, or a reply whose session id chip shows its card
/// on hover.
function GallerySessionHover({ mode }: Props) {
  // The card where it shows in the app: over the transcript, beside a user bubble it must not read as.
  if (mode === "reply")
    return (
      <div className="acpmux-shell">
        <div data-hover-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
          <div className="acpmux-user" style={{ marginBottom: 12 }}>
            <div className="acpmux-user-bubble">Run the merge-freeze switch as a background chat.</div>
          </div>
          <div
            className="ui-tooltip ui-card ui-glass acpmux-session-hover-card"
            style={{ position: "static", width: "fit-content" }}
          >
            <SessionHoverContent info={hoverInfo(chipEntry)} onOpen={() => undefined} />
          </div>
        </div>
      </div>
    );
  // A message's sender names a listed chat: its name shows the same card.
  if (mode === "sender")
    return (
      <div className="acpmux-shell">
        <div data-hover-fixture style={{ flex: 1, minWidth: 0, padding: 12, height: 200 }}>
          <SubsessionContext.Provider value={{ store: subsessions, open: () => undefined }}>
            <SessionHoverContext.Provider value={{ store, open: () => undefined }}>
              <IncomingMessageLine
                id="hover-sender"
                message={{
                  name: "lane-host-2/merge-freeze",
                  text: "The merge check reads the freeze issues now.",
                  raw: "[lane-host-2/merge-freeze] The merge check reads the freeze issues now.",
                }}
                onOpen={() => undefined}
              />
            </SessionHoverContext.Provider>
          </SubsessionContext.Provider>
        </div>
      </div>
    );
  if (mode === "chip")
    return (
      <div className="acpmux-shell">
        <div data-hover-fixture style={{ flex: 1, minWidth: 0, padding: 12, height: 160 }}>
          <SessionHoverContext.Provider value={{ store, open: () => undefined }}>
            <p className="cv-md">
              Started{" "}
              <StartedSessionChip
                mention={{
                  text: "Switch gh-merge-green to merge-freeze issues",
                  sessionId: CHIP_ID,
                  title: "Switch gh-merge-green to merge-freeze issues",
                  state: "running",
                }}
                text="Switch gh-merge-green to merge-freeze issues"
                onOpen={() => undefined}
              />{" "}
              in the background.
            </p>
          </SessionHoverContext.Provider>
        </div>
      </div>
    );
  return (
    <div className="acpmux-shell">
      <div data-hover-fixture style={{ display: "flex", flexWrap: "wrap", gap: 12, padding: 12 }}>
        {cards.map((info) => (
          <div
            key={info.sessionId}
            className="ui-tooltip ui-card ui-glass acpmux-session-hover-card"
            style={{ position: "static" }}
          >
            <SessionHoverContent info={info} onOpen={() => undefined} />
          </div>
        ))}
      </div>
    </div>
  );
}

const hoverChip: Play = async (ctx) => {
  const chip = ctx.document.querySelector<HTMLElement>(".acpmux-started-chip")!;
  chip.focus();
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-hover-card"));
};

const hoverSender: Play = async (ctx) => {
  const name = ctx.document.querySelector<HTMLElement>("[data-open-session]")!;
  name.focus();
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-hover-card"));
};

export default componentEntry<Props>({
  id: "agent-pane.session-hover",
  title: "Session hover card",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-hover-fixture]" }],
  covers: [
    "agent-session/acpmux/started/SessionHoverCard.tsx#SessionHoverContent",
    "agent-session/acpmux/started/SessionHoverCard.tsx#SessionHoverContext",
    "agent-session/acpmux/conversation/AgentTag.tsx",
  ],
  styles: () => import("../styles.css"),
  load: async () => GallerySessionHover,
  variants: {
    states: {
      note: 'Each kind of status line under the title, then what the chat does now (a running turn\'s step and tool, what it waits on you for, else its latest reply, muted) and its folder, branch and last change. Leo, 2026-11-05: "the metadata.... ehh..".',
      props: { mode: "states" },
    },
    reply: {
      note: "The card over the transcript beside a user bubble: the glass hover card (the popup surface under plain glass), its rim and the hover card elevation, then the title, the status row and the folder and branch.",
      props: { mode: "reply" },
      height: 180,
    },
    chip: {
      note: "Play: focus on a reply's session chip shows its card at once; the pointer waits 500 ms first.",
      props: { mode: "chip" },
      height: 200,
      play: hoverChip,
    },
    sender: {
      note: "Play: a message sender's name that is one of your chats shows the same card (its running step, folder, branch and last change); its right-click is that chat's menu.",
      props: { mode: "sender" },
      height: 240,
      play: hoverSender,
    },
  },
});
