// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Where a slow Cloud resume says so (Leo, 2026-11-03: the wait "you mostly perceive as "thinking"
// / But it's all still responsive on the ui side"). A prompt sent to a paused machine leaves the
// composer at once; for the first 1.5 s nothing says the machine is waking (the `*-quick`
// variants), and past that one quiet line does. Three places for that line; `queue` ships.
import { componentEntry } from "../../gallery/format";
import type { CloudResumeDesignsProps } from "./CloudResumeDesigns";

export default componentEntry<CloudResumeDesignsProps>({
  id: "agent-pane.cloud-resume-designs",
  title: "A slow Cloud resume: where the note goes (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/CloudResumeDesigns.tsx#CloudResumeDesigns"],
  styles: () => Promise.all([import("./styles.css"), import("./composerStates.css")]),
  load: () => import("./CloudResumeDesigns").then((module) => module.CloudResumeDesigns),
  widths: { narrow: 400, normal: 620 },
  height: 360,
  variants: {
    "queue-quick": {
      note: "Resuming, under 1.5 s: the held prompt shows with an empty line over it; nothing says the machine is waking.",
      props: { design: "queue", slow: false },
    },
    queue: {
      note: "Picked, and the one that ships: past 1.5 s, Waking the machine… fades into the line over the held prompt. It sits on the thing that waits, its line was there already, and it adds no surface.",
      props: { design: "queue", slow: true },
    },
    footer: {
      note: "A line under the composer's input: it reads as a composer state, not the sent prompt's, and the prompt still sits in the input.",
      props: { design: "footer", slow: true },
    },
    transcript: {
      note: "A line under the last reply, where the answer will stream: closest to thinking, but the prompt it waits on is not there yet.",
      props: { design: "transcript", slow: true },
    },
    "transcript-quick": {
      note: "The transcript design under 1.5 s: its empty line.",
      props: { design: "transcript", slow: false },
    },
  },
});
