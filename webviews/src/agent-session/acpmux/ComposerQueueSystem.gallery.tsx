// l10n-allow-file: gallery fixtures (sample prompts and subagent names), not shipped UI.
// acpmux's own queued prompts apart from the person's steer rows (ComposerQueue.tsx `SystemNotes`).
// Leo, 2026-11-24: "these held during message surge, esume subagent things... maybe shouldn't look
// liek they're in the steer thing. because why would a user steer or whatever on these? they should
// be separated out from the user visible steer ui area. maybe not even interactable?" And, on the
// same rows: "if the buttons show on hover, then we should show the whole line before ellipsis-ing."
import { componentEntry } from "../../gallery/format";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { Composer } from "./Composer";
import type { SystemLook } from "./ComposerQueue";
import type { AcpmuxSnapshot } from "./model";

type Props = { look?: SystemLook; before?: boolean };

const SURGE =
  "Held during a message surge: 10 message(s) in 8 thread(s) need you. Read them with inbox_read and answer each in its thread.";
const RESUME =
  'Your subagent "Sweep hover rows" (agent id abb9624d75985f07d) failed on a transient upstream error (529). Resume it';
const MINE = "Then check every row that keeps room for a button that only shows on hover, and give them one layout";

function queue(before: boolean): AcpmuxSnapshot["queue"] {
  const own = { id: "p-own", prompt: MINE };
  if (before) return [{ id: "d-surge", prompt: SURGE }, { id: "r-resume", prompt: RESUME }, own];
  return [
    { id: "d-surge", prompt: SURGE, system: "surge_digest" },
    {
      id: "r-resume",
      prompt: RESUME,
      system: "subagent_retry",
      retry: { name: "Sweep hover rows", agentId: "abb9624d75985f07d", error: "529" },
    },
    own,
  ];
}

function snapshot(before: boolean): AcpmuxSnapshot {
  const base = chat(
    [user("Fix the queue rows' early ellipsis", 4), assistant("Working on the shared row layout now.", 3)],
    { title: "Queue rows", harness: "claude", model: "opus" },
  );
  return { ...base, summary: { ...base.summary!, status: "running" }, queue: queue(before) };
}

const NoChips = () => null;

function Stage({ look = "band", before = false }: Props) {
  return (
    <section className="acpmux-shell" style={{ height: "100%" }}>
      <div className="acpmux-main">
        <div className="acpmux-stage" />
        <div className="acpmux-dock">
          <Composer
            snapshot={snapshot(before)}
            queueSystemLook={look}
            chips={NoChips}
            onSend={() => true}
            onStop={() => undefined}
          />
        </div>
      </div>
    </section>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.queue-system-notes",
  title: "acpmux's own queued prompts",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 420, normal: 760 },
  covers: ["agent-session/acpmux/ComposerQueue.tsx#ComposerQueue"],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerStates.css"),
      import("./bottomStack.css"),
      import("./conversation/conversation.css"),
    ]),
  load: async () => Stage,
  variants: {
    before: {
      props: { before: true },
      note: "Before: the surge digest and the subagent's resume drew as the person's steer rows, with Steer, edit and delete, and every row kept a column for buttons that show only on hover.",
    },
    band: {
      props: { look: "band" },
      note: "The pick: acpmux's own prompts are their own small muted card above the person's queue, one line each, no actions; a click opens one to its whole text. The person's rows run their text the whole width; hover fades the end out as the buttons fade in.",
    },
    below: {
      props: { look: "below" },
      note: "Alternative: the same notes under the person's rows, next to the composer. Lost: what the person typed should sit nearest to where they type.",
    },
    summary: {
      props: { look: "summary" },
      note: "Alternative: one line naming every note, which opens to the list. Lost: a second click for a list that is rarely more than two lines.",
    },
  },
});
