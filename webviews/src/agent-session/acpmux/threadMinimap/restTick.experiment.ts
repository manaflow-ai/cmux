// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt rail's resting ticks keep their spacing where its gutter runs short: Session Info
/// pushing the chat's column toward the left rail, or a narrow pane (Leo, 2026-11-06: "you guys didn't
/// fix the spacing on this left side session rail thing"; 2026-10-27, of the rail at rest: the padding
/// should go first, not the rail being squeezed to half width). The rail's hit width shrinks there so
/// the text keeps its clicks, and the tick's line box shrank with it (`min(26px, 100%)`): a pushed left
/// rail drew its resting ticks 4.6 px long beside the right rail's 6, a narrow pane's 2.8, and the
/// bookmark dot stayed where a full tick ends, off its tick.
///
/// `steady`, the default, keeps the tick's line box at its 26 px in every width: the resting ticks are
/// one length on either side, in every pane and with Session Info open, closed or pushing; only the
/// room between the ticks and the text shrinks. `squeeze` is the earlier box that shrank with the hit
/// width. `inset-first` keeps steady ticks and also shrinks the rail's edge inset before its width, so
/// the ticks keep more room from the text, but it moves the rail when Session Info pushes.
/// Dogfood switches from `cmux.experiments`: {"thread-minimap-rest-tick":"squeeze"}.
export const threadMinimapRestTick = defineExperiment({
  id: "thread-minimap-rest-tick",
  title: "Prompt rail resting ticks",
  description: "Whether a short gutter shortens the prompt rail's resting ticks, or only the room beside them.",
  arms: {
    steady: {
      label: "Steady ticks",
      description: "Every resting tick keeps its length; only the room between the ticks and the text shrinks.",
    },
    squeeze: {
      label: "Squeezed ticks",
      description: "The ticks' line box shrinks with the rail's hit width, so a short gutter shortens them.",
    },
    "inset-first": {
      label: "Inset first",
      description: "Steady ticks, and the edge inset shrinks before the hit width, moving the rail as the text nears.",
    },
  },
  defaultArm: "steady",
});
