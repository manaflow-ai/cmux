// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a file chip's icon says what the file is. ChatGPT's report gives each supporting artifact
/// its own small icon (a page for a document, braces for data, a log mark); every file chip here drew
/// the same page (Leo, 2026-11-02, on ChatGPT's long report: "see this is the kinda scenario we
/// wanna be able to display super nicely"). Compare in the gallery's `agent-pane.path-chip`.
export const fileKindIcon = defineExperiment({
  id: "file-kind-icon",
  title: "File chip icon by kind",
  description: "Whether a file chip's icon follows the file's kind (document, code or data, log) or stays one page.",
  arms: {
    typed: {
      label: "Typed",
      description: "A page for documents, braces for code and data, a terminal mark for logs.",
    },
    "code-only": {
      label: "Code or page",
      description: "Braces for code, data and logs; a page for everything else.",
    },
    page: { label: "One page", description: "The same page for every file, as before." },
  },
  defaultArm: "typed",
});
