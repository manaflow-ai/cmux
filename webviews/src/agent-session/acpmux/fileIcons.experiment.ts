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

/// The @ picker's file icons and a badge's language icon in their type's color (Swift orange,
/// Python blue), from the theme's ANSI colors, as Claude desktop's picker and the Files page draw
/// them; `muted` draws them in the muted text color, as the chat's diff headers do.
export const fileIconColor = defineExperiment({
  id: "file-icon-color",
  title: "File icon color",
  description:
    "File-type and language icons in the @ picker and project badges: in their type's theme color, or muted.",
  arms: {
    theme: {
      label: "Theme color",
      description: "Each type in its ANSI theme color (Swift orange, Python blue, YAML red).",
    },
    muted: { label: "Muted", description: "Every icon in the muted text color, as the chat's diff headers." },
  },
  defaultArm: "theme",
});
