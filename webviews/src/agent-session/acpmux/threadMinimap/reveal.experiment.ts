// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the pane-edge strip and the rail's hover treat a pointer that is selecting text (Leo, 2026-11-22:
/// "the scroll rail is slightly too sensitive to stuff when at small sizes ... there's a lot of
/// awkwardness when you try to e.g. copy text along this area"). `intent`, the default, reveals the
/// occluded rail only for a pointer at rest (railIntent.ts REVEAL_DWELL) and gives the rail no pointer
/// while a press that began in the text is down. `press-guard` keeps only the second half. `immediate` is
/// the earlier behavior: the strip reveals on the frame the pointer touches it, drag or not.
/// Dogfood switches from `cmux.experiments`: {"thread-minimap-reveal":"immediate"}. The arms apply only
/// with the person's switch on (REST_REVEAL_SWITCH, `experiments.threadMinimapRestReveal`, default off);
/// off, every pane keeps `immediate`.
export const threadMinimapReveal = defineExperiment({
  id: "thread-minimap-reveal",
  title: "Prompt rail reveal intent",
  description: "Whether the rail waits for a resting pointer and stays out of a selection drag.",
  arms: {
    intent: {
      label: "Rest and no drag",
      description: "Reveals after the pointer rests 140 ms with no button down; a press in the text keeps it inert.",
    },
    "press-guard": {
      label: "No drag only",
      description: "Reveals at once, but never under a press that began in the text.",
    },
    immediate: {
      label: "Immediate",
      description: "The earlier behavior: the strip reveals the rail on touch, even mid-drag.",
    },
  },
  defaultArm: "intent",
});

/// The Settings > Advanced > Experiments switch (`experiments.threadMinimapRestReveal`) that turns the
/// arms above on. Off by default (Leo's UI merge hold, 2026-11-24).
export const REST_REVEAL_SWITCH = "threadMinimapRestReveal";
