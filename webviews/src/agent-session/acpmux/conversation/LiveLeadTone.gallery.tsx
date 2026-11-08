// l10n-allow-file: gallery fixture prose and tool names, not shipped copy.
// The live line's action word and the rest of its words in one tone (Leo, 2026-11-07: "The, like,
// white text, the verb, or whatever the ing verb, why is it white? Why was it made white in the
// first place? ... Two, don't make it white."). `muted` ships: the action reads in the line's own
// muted tone and the shimmer is the line's only lift. The other looks are kept to compare: `ink` is
// #33241's full-ink action, `weight` lifts the action by weight at the muted tone, `soft` halfway
// between. References: cmux/live/status-working-timer-and-token-count,
// claude/live/status-thinking-line-token-counts, claude/live/transcript-tool-rows-and-task-list.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { Thinking } from "./Thinking";
import { WorkingCountsContext } from "./workingForModel";
import { type WorkingCounts } from "./workingForModel";

type Look = "muted" | "ink" | "weight" | "soft";
type Props = { look: Look };

const START = Date.UTC(2026, 10, 7, 8, 0, 0);
const now = () => START + 182_000;
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 47_400,
};

/// Leo's line ("Writing a comm…"), an MCP call and a running command.
const LINES = ["Writing a command", "Using repo: repo grep", "Running ffmpeg -v error -i clip.mov"];

function LiveLeadTone({ look }: Props) {
  return (
    <main className="live-lead-tone acpmux-conversation" data-look={look}>
      <WorkingCountsContext.Provider value={counts}>
        {LINES.map((doing) => (
          <div key={doing} className="acpmux-row acpmux-thinking">
            <Thinking since={START} now={now} doing={doing} below />
          </div>
        ))}
      </WorkingCountsContext.Provider>
    </main>
  );
}

const variant = (look: Look, note: string): ComponentVariant<Props> => ({ note, props: { look } });

export default componentEntry<Props>({
  id: "agent-pane.live-lead-tone",
  title: "The live line's action word, in the line's tone",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 320, normal: 640 },
  covers: ["agent-session/acpmux/conversation/Thinking.tsx", "agent-session/acpmux/conversation/conversation.css"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./LiveLeadTone.gallery.css")]),
  load: async () => LiveLeadTone,
  keywords: ["live", "lead", "verb", "muted", "white", "ink", "shimmer", "writing", "running"],
  variants: {
    muted: variant("muted", "Chosen: the action in the line's muted tone; the shimmer is its only lift."),
    ink: variant("ink", "Before (#33241): the action in full ink, the rest muted."),
    weight: variant("weight", "The action at the muted tone, lifted by a medium weight instead."),
    soft: variant("soft", "The action halfway between the muted tone and full ink."),
  },
});
