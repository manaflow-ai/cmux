// l10n-allow-file: gallery prototype fixtures, not shipped UI.
// The typing indicator of Chief and agents (Lawrence 2026-10-19): before the first token, while a
// tool runs, while streaming, and done, in five designs.
import { componentEntry } from "../../gallery/format";
import type { TypingIndicatorProps } from "./TypingIndicator";

export default componentEntry<TypingIndicatorProps>({
  id: "subagents.typing-indicator",
  title: "Subagents: typing indicator",
  area: "Subagent books",
  keywords: ["typing", "dots", "chief", "streaming", "caret", "bubble", "working", "ios", "mac"],
  covers: ["prototypes/subagents/TypingIndicator.tsx"],
  load: () => import("./TypingIndicator").then((module) => module.TypingIndicator),
  height: 920,
  widths: { narrow: 440, normal: 1280, wide: 1600 },
  options: [
    {
      id: "platform",
      label: "Frame",
      kind: "choice",
      choices: [
        { value: "mac", label: "Mac" },
        { value: "iphone", label: "iPhone" },
      ],
      defaultValue: "mac",
    },
    {
      id: "phase",
      label: "Phase",
      kind: "choice",
      choices: [
        { value: "waiting", label: "Before first token" },
        { value: "tool", label: "Running a tool" },
        { value: "streaming", label: "Streaming" },
        { value: "done", label: "Done" },
      ],
      defaultValue: "waiting",
    },
    {
      id: "who",
      label: "Who",
      kind: "choice",
      choices: [
        { value: "chief", label: "Chief" },
        { value: "agent", label: "Agent" },
      ],
      defaultValue: "chief",
    },
  ],
  variants: {
    dots: { note: "Three crisp dots, then the text itself.", props: { platform: "mac", design: "dots", phase: "waiting" } },
    shimmer: { note: "cnx-ios WorkingLabel: the word shimmers; elapsed time from 5 s.", props: { platform: "mac", design: "shimmer", phase: "waiting" } },
    bubble: { note: "Messages typing bubble (Chief on iPhone).", props: { platform: "iphone", design: "bubble", phase: "waiting" } },
    caret: { note: "A block caret where the text will start; it rides the end while streaming.", props: { platform: "mac", design: "caret", phase: "streaming" } },
    composer: { note: "Original: the state lives on the composer (with Stop), the transcript stays still.", props: { platform: "mac", design: "composer", phase: "streaming" } },
  },
});
