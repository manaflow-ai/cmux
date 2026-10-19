// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { sessionEntry } from "../sessionList";
import { type HoverState, SessionHoverStore } from "./sessionHover";
import { SessionHoverContent, SessionHoverContext } from "./SessionHoverCard";
import { StartedSessionChip } from "./StartedSessionCard";

type Props = { mode: "states" | "chip" };

const NOW = Date.now();
const titles: Record<HoverState, string> = {
  running: "Switch gh-merge-green to merge-freeze issues",
  unread: "Triage the 10 failing Swift tests at the tip",
  waiting: "Rename the settings keys",
  done: "Bump the Ghostty pin",
  failed: "Fix the flaky sidebar test",
};
const ages: Record<HoverState, number> = { running: 0, unread: 4, waiting: 12, done: 180, failed: 60 * 26 };

const CHIP_ID = "01a0ebd5-0efe-721d-9edc-cf1a6ba78d98";
const store = new SessionHoverStore();
store.set([
  sessionEntry({
    sessionId: CHIP_ID,
    title: titles.running,
    cwd: "/Users/you/Projects/cmux",
    indicator: "working",
    updatedAt: NOW,
  }),
]);

/// Each state's card as it shows over a reference, or a reply whose session id chip shows its card
/// on hover.
function GallerySessionHover({ mode }: Props) {
  if (mode === "chip")
    return (
      <div className="acpmux-shell">
        <div data-hover-fixture style={{ flex: 1, minWidth: 0, padding: 12, height: 160 }}>
          <SessionHoverContext.Provider value={{ store, open: () => undefined }}>
            <p className="cv-md">
              Started{" "}
              <StartedSessionChip
                mention={{ text: titles.running, sessionId: CHIP_ID, title: titles.running, state: "running" }}
                text={titles.running}
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
        {(Object.keys(titles) as HoverState[]).map((state) => (
          <div key={state} className="ui-tooltip ui-card acpmux-session-hover-card" style={{ position: "static" }}>
            <SessionHoverContent
              info={{
                sessionId: state,
                title: titles[state],
                state,
                project: "cmux",
                updatedAt: NOW - ages[state] * 60_000,
              }}
              now={NOW}
              onOpen={() => undefined}
            />
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
    "agent-session/acpmux/started/SessionHoverCard.tsx#SessionStatePill",
    "agent-session/acpmux/started/SessionHoverCard.tsx#SessionHoverContext",
  ],
  styles: () => import("../styles.css"),
  load: async () => GallerySessionHover,
  variants: {
    states: {
      note: "Each state's card: running (the bare spinner), new activity, needs input, done and failed, with the project and age.",
      props: { mode: "states" },
    },
    chip: {
      note: "Play: focus on a reply's session chip shows its card at once; the pointer waits 500 ms first.",
      props: { mode: "chip" },
      height: 200,
      play: hoverChip,
    },
  },
});
