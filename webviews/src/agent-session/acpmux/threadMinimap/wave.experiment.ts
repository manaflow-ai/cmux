// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The shape of the compact rail's hover magnification (the Dock-like wave). Leo, 2026-11-03: "i
/// feel like our animation isn't as good as chatgpt's for it, it doesn't feel as wave-y as
/// chatgpt's. something about easing or whatever idk it doesn't feel smooth when you're hoving your
/// mouse through it". The stepped arm is the fisheye as it was: lengths by whole rows from the
/// hovered row (26, 20, 14, 10, then 6 px), each tick on its own 120 ms transition, so a sweep moved
/// in row-sized jumps. The other arms follow the pointer's own y: each tick's length is a smooth bump
/// of its fractional distance from the pointer (model.ts `waveProgress`), eased by one loop
/// (hoverWave.ts). Leo, later that day: "the in-between feels a bit strange and gooey i'd rather keep
/// it per zipper rail thing", "chatgpt has an animation for when it shrinks", and "you guys kinda
/// messed up the selected one being the center tallest one". The zipper arm ships: the stepped
/// lengths (ChatGPT's own), the hovered tick always the single longest, each tick easing on its own
/// to its new length as the hovered row changes, and the ticks shrinking back to rest when the
/// pointer leaves (model.ts `zipRetarget`). The gallery compares them mid-sweep. Dogfood switches
/// from `cmux.experiments`: {"thread-minimap-wave":"cosine-4"}.
export const threadMinimapWave = defineExperiment({
  id: "thread-minimap-wave",
  title: "Thread minimap hover wave",
  description:
    "How the compact rail's ticks grow around the pointer: stepped by row, or a smooth bump that follows it.",
  arms: {
    stepped: {
      label: "Stepped",
      description: "Lengths by whole rows from the hovered row, as before: 26, 20, 14, 10 px.",
    },
    zipper: {
      label: "Zipper",
      description:
        "Lengths by whole rows from the hovered row (26, 20, 14, 10 px), each tick easing to its own; shrinks back on leave.",
    },
    "cosine-4": {
      label: "Cosine, 4 rows",
      description:
        "A raised-cosine bump that reaches rest 4 rows from the pointer (the stepped reach), following its y.",
    },
    "cosine-5": {
      label: "Cosine, 5 rows",
      description: "A wider raised-cosine bump, at rest 5 rows from the pointer.",
    },
    gaussian: { label: "Gaussian", description: "A bell (sigma 1.4 rows) that tapers to rest by 4.5 rows." },
  },
  defaultArm: "zipper",
});

export type WaveArm = keyof typeof threadMinimapWave.arms;
