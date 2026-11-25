// l10n-allow-file: synthetic gallery transcript and comparison labels.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER } from "../model";
import { threadMinimapCutover, type CutoverLook } from "./cutover.experiment";

const key = "gallery-rail-cutover:17";
const history = Array.from({ length: 14 }, (_, at) => [
  user(`Check migration step ${at + 1}`, 40 - at * 2),
  assistant(`Step ${at + 1} passes on the staging database.`, 39 - at * 2),
]).flat();
const line = row(SINCE_DIVIDER, 24, { id: SINCE_DIVIDER, since: { key, seq: 17, turns: 6 } });
// The reader left after asking the eighth question, before its reply arrived.
const snapshot = chat([...history.slice(0, 15), line, ...history.slice(15)], { sinceKey: key, sinceLands: true });
const look = (arm: CutoverLook, note: string) => ({
  note,
  snapshot,
  experiments: { [threadMinimapCutover.id]: arm },
});

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-cutover",
  title: "Where you left off in the thread rail",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx", "agent-session/acpmux/threadMinimap/ScrollMap.tsx"],
  variants: {
    tick: look("tick", "A short accent rule after the eighth prompt mirrors the New line in the chat."),
    band: look("band", "A translucent band spans the rail at the same cutover."),
    dot: look("dot", "A small accent dot sits between the eighth and ninth prompts."),
    "first-visit": { note: "A chat opened for the first time has ordinary prompt ticks.", snapshot: chat(history) },
  },
});
