// l10n-allow-file: gallery prototype fixtures, not shipped UI.
// Subagents inside a conversation (Lawrence 2026-10-19): five ways the transcript shows children
// the turn started, with live state; a click opens the child in place.
import { componentEntry } from "../../gallery/format";
import type { ConversationSubagentsProps } from "./ConversationSubagents";

export default componentEntry<ConversationSubagentsProps>({
  id: "subagents.in-conversation",
  title: "Subagents: in the conversation",
  area: "Subagent books",
  keywords: ["chips", "cards", "spawn", "children", "transcript", "inline", "ios", "mac"],
  covers: ["prototypes/subagents/ConversationSubagents.tsx"],
  load: () => import("./ConversationSubagents").then((module) => module.ConversationSubagents),
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
    { id: "count", label: "Children", kind: "choice", choices: ["3", "8", "20", "50"], defaultValue: "8", numeric: true },
    {
      id: "phase",
      label: "State",
      kind: "choice",
      choices: [
        { value: "live", label: "Live" },
        { value: "finished", label: "Finished" },
      ],
      defaultValue: "live",
    },
    { id: "opened", label: "Child open", kind: "toggle", defaultValue: false },
  ],
  variants: {
    chips: { note: "Small-radius chips with a status mark; running ones show their time.", props: { platform: "mac", design: "chips", count: 8 } },
    cards: { note: "Compact cards: the newest event shimmers; grandchildren as a thin progress line.", props: { platform: "mac", design: "cards", count: 8 } },
    line: { note: "One summary line with stacked marks; opens to a list.", props: { platform: "mac", design: "line", count: 8 } },
    tree: { note: "A nested tree card: children and their own subagents.", props: { platform: "mac", design: "tree", count: 8 } },
    toolrows: { note: "Tool-row style (cnx-ios 6.4): one grouped row, expanded while running.", props: { platform: "mac", design: "toolrows", count: 8 } },
    "child-open": { note: "A child opened in place, with its parent as the back target.", props: { platform: "mac", design: "chips", count: 8, opened: true } },
    "many-children": { note: "50 children.", props: { platform: "mac", design: "line", count: 50 } },
  },
});
