// l10n-allow-file: gallery fixtures (made-up people), not shipped UI.
// A shared chat's people (hq plans/cmux-next/chat-multiplayer/DESIGN.md; Leo, 2026-10-26: "we can
// still do the regular chat multiplayer"): the author over a prompt, who else is here in the
// header, who is typing, and who answered an ask, in three looks. The pick is `picked`: a face
// and name over the prompt, overlapping faces in the header, and face + words + a dot wave.
import { componentEntry } from "../../../gallery/format";
import type { FacesDemoProps } from "./FacesDemo";
import { ANA, JORDAN, MEI, SAM } from "./people.fixtures";

const base = { viewing: [ANA, SAM, MEI, JORDAN], typers: [ANA], sender: SAM, answerer: MEI };

export default componentEntry<FacesDemoProps>({
  id: "agent-pane.multiplayer-looks",
  title: "Agent pane: shared chat people (looks)",
  area: "Agent pane",
  keywords: ["multiplayer", "presence", "typing", "author", "avatar", "shared chat", "answered by"],
  covers: ["agent-session/acpmux/multiplayer/Faces.tsx", "agent-session/acpmux/multiplayer/FacesDemo.tsx"],
  load: () => import("./FacesDemo").then((module) => module.FacesDemo),
  height: 320,
  variants: {
    picked: {
      note: "The pick: face and name over the prompt, overlapping faces with +N, face + words + dot wave.",
      props: { ...base, author: "face-name", presence: "stack", typing: "dots" },
    },
    names: {
      note: "Words only: the name over the prompt, faces with first names, the typing words alone.",
      props: { ...base, author: "name", presence: "names", typing: "text" },
    },
    faces: {
      note: "Faces only: a face over the prompt, the stack, faces with the dot wave (names for screen readers).",
      props: { ...base, author: "face", presence: "stack", typing: "faces" },
    },
    "two-typing": {
      note: "Two people typing at once, the picked looks.",
      props: { ...base, typers: [ANA, SAM], author: "face-name", presence: "stack", typing: "dots" },
    },
  },
});
