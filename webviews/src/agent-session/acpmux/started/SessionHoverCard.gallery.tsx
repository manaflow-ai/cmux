// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { sessionEntry } from "../sessionList";
import { type SessionHoverInfo, SessionHoverStore, hoverInfo } from "./sessionHover";
import { SessionHoverContent, SessionHoverContext } from "./SessionHoverCard";
import { StartedSessionChip } from "./StartedSessionCard";

type Props = { mode: "states" | "chip" | "reply" };

const NOW = Date.now();
/// One card for each kind of status line: a PR's status, needs input, failed, running, new activity, done.
const cards: SessionHoverInfo[] = [
  {
    sessionId: "c-1",
    title: "Switch gh-merge-green to merge-freeze issues",
    status: "failing",
    pullRequests: { count: 2, tone: "failing", number: 22092, repo: "cmux" },
  },
  {
    sessionId: "c-2",
    title: "Bump the Ghostty pin",
    status: "merged",
    pullRequests: { count: 1, tone: "merged", number: 22164, repo: "cmux" },
  },
  { sessionId: "c-3", title: "Rename the settings keys", status: "waiting" },
  {
    sessionId: "c-4",
    title: "Fix the flaky sidebar test",
    status: "failed",
    pullRequests: { count: 1, tone: "failing", number: 22163, repo: "cmux" },
  },
  { sessionId: "c-5", title: "Draft the release notes", status: "running" },
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
  updatedAt: NOW,
  pullRequests: ["https://github.com/manaflow-ai/cmux/pull/22092"],
  pullRequest: { number: 22092, title: "Switch gh-merge-green", state: "open", checks: "failing" },
});
const store = new SessionHoverStore();
store.set([chipEntry]);

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
  ],
  styles: () => import("../styles.css"),
  load: async () => GallerySessionHover,
  variants: {
    states: {
      note: "Each kind of status line under the title: checks failed and merged PRs, needs input, failed, running (the bare spinner), new activity and done.",
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
  },
});
