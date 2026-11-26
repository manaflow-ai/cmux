// l10n-allow-file: gallery fixtures (made-up people and agents), not shipped UI.
// A shared chat's room strip (RFD 0141 phase 2): faces of the people and agents in the room in the
// daemon's order (acting first, people before agents, away last) with "+N", and one activity line
// that says who types and which agent works. Agents in a private chat and anyone with Live off
// never reach the strip, so no fixture shows them.
import { componentEntry } from "../../../gallery/format";
import type { StripDemoProps } from "./StripDemo";
import type { StripActor, StripFace } from "./roomStrip";
import { ANA, JORDAN, MEI, SAM } from "./people.fixtures";

const face = (who: { id: string; name: string }, kind: "person" | "agent", doing = "idle", status = "live") =>
  ({ ...who, kind, doing, status }) as StripFace;
const actor = ({ id, name, kind, doing }: StripFace): StripActor => ({ id, name, kind, doing });
const CLAUDE = { id: "session:s1", name: "Claude" };
const CODEX = { id: "session:s2", name: "Codex" };

const anaTyping = face(ANA, "person", "typing");
const claudeRunning = face(CLAUDE, "agent", "running");
const codexEditing = face(CODEX, "agent", "editing");

export default componentEntry<StripDemoProps>({
  id: "agent-pane.room-strip",
  title: "Agent pane: room avatar strip",
  area: "Agent pane",
  keywords: ["multiplayer", "presence", "live", "avatar strip", "typing", "agent running", "rfd 0141"],
  covers: [
    "agent-session/acpmux/multiplayer/Faces.tsx",
    "agent-session/acpmux/multiplayer/StripDemo.tsx",
    "agent-session/acpmux/multiplayer/roomStrip.ts",
  ],
  load: () => import("./StripDemo").then((module) => module.StripDemo),
  height: 160,
  variants: {
    picked: {
      note: "A person typing and an agent running lead the strip; one line names both.",
      props: {
        strip: {
          faces: [anaTyping, claudeRunning, face(SAM, "person")],
          more: 1,
          line: { actors: [actor(anaTyping), actor(claudeRunning)], more: 0 },
        },
      },
    },
    "agents-only": {
      note: "Two agents at work, nobody typing: the line names each agent.",
      props: {
        strip: {
          faces: [claudeRunning, codexEditing],
          more: 0,
          line: { actors: [actor(claudeRunning), actor(codexEditing)], more: 0 },
        },
      },
    },
    quiet: {
      note: "Everyone idle, one away (dimmed): faces only, no line.",
      props: { strip: { faces: [face(MEI, "person"), face(CLAUDE, "agent"), face(JORDAN, "person", "idle", "away")], more: 0 } },
    },
    crowded: {
      note: "Three acting and more past the line: two named, then +N; the stack shows +N too.",
      props: {
        strip: {
          faces: [anaTyping, claudeRunning, codexEditing],
          more: 4,
          line: { actors: [actor(anaTyping), actor(claudeRunning)], more: 1 },
        },
      },
    },
  },
});
