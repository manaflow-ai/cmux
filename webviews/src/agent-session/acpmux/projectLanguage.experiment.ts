// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// A project badge with no favicon draws its language's icon (Swift, Rust, Next.js, from the
/// project's marker files) instead of its letters (Leo, 2026-10-19). On by default; `off` keeps the
/// letters: {"project-language-icons":"off"} in `cmux.experiments`.
export const projectLanguageIcons = defineExperiment({
  id: "project-language-icons",
  title: "Project language icons",
  description: "A project without a favicon shows its language or framework icon in its badge instead of its letters.",
  arms: {
    on: { label: "Language", description: "Swift, Rust, Python, Next.js and so on from the project's marker files." },
    off: { label: "Letters", description: "The project's initials on its color, as before." },
  },
  defaultArm: "on",
});
