// l10n-allow-file: gallery fixtures (a recorded chat), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { EventRecord } from "../direct";
import type { ReplayScreen } from "./ReplayScreen";
import { REPLAY_SESSION, replayFixtureEvents } from "./replayFixture";

type Props = Omit<Parameters<typeof ReplayScreen>[0], "transcript">;

const base = { sessionId: REPLAY_SESSION, title: "Fix the flaky retry test", onClose: () => undefined };
const loaded = () => Promise.resolve(replayFixtureEvents());
const never = () => new Promise<EventRecord[]>(() => undefined);
const failed = () => Promise.reject(new Error("unreachable"));
const empty = () => Promise.resolve([]);

export default componentEntry<Props>({
  id: "agent-pane.replay",
  title: "Session replay",
  area: "Agent pane",
  height: 640,
  experimental: true,
  covers: ["agent-session/acpmux/replay/ReplayScreen.tsx#ReplayScreen"],
  pane: true,
  // The pane draws the replayed rows with its own transcript.
  load: () =>
    Promise.all([import("./ReplayScreen"), import("../App")]).then(
      ([{ ReplayScreen }, { VirtualTranscript }]) =>
        function GalleryReplay(props: Props) {
          return (
            <ReplayScreen
              {...props}
              transcript={(rows) => (
                <VirtualTranscript
                  rows={rows}
                  sessionId="replay"
                  expanded={new Set()}
                  onToggleActivity={() => undefined}
                />
              )}
            />
          );
        },
    ),
  variants: {
    playing: { props: { ...base, load: loaded }, note: "Plays from the first prompt; the 45 s wait plays as 2 s" },
    loading: { props: { ...base, load: never } },
    failed: { props: { ...base, load: failed } },
    empty: { props: { ...base, load: empty } },
  },
});
