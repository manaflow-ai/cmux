// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// The reply's prose measure (Instrument v0.1, design debate 2026-11-22): at the default Chat Text Width
/// (800) a reply's paragraphs, headings, lists and quotes stop at about 680 px, while its code blocks,
/// tables and diffs keep the whole column; tool rows draw one type size under the prose (13 on the
/// default 14). A person who set another Chat Text Width or Chat Full Width gets their width for
/// everything. The classic arm draws prose across the whole 800 column and tool rows at the prose size.
/// To switch back, set `cmux.experiments` to `{"prose-measure":"classic"}` in the pane's web inspector
/// and reload.
export const proseMeasure = defineExperiment({
  id: "prose-measure",
  title: "Prose measure",
  description:
    "How wide a reply's prose runs and how big tool rows are. Instrument stops prose at about 680 px inside the 800 column (code and diffs stay wide) and draws tool rows a size under the prose; Classic runs prose across the column and draws tool rows at the prose size.",
  arms: {
    instrument: {
      label: "Instrument",
      description: "Prose about 680 px wide, code and diffs 800, tool rows 13 under 14 prose.",
    },
    classic: { label: "Classic", description: "Prose across the whole 800 column, tool rows at the prose size." },
  },
  defaultArm: "instrument",
});

/// The prose measure in CSS px at page zoom 1 (conversation.css `--cv-prose-measure`).
export const PROSE_MEASURE = 680;
