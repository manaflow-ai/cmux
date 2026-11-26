// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How often a streaming chat draws while its page misses frames (loadCoalesce.ts). Leo, 2026-11-09:
/// "i wonder if we can do a thing where like at minimal ish mode? and just does things as fast as it
/// can/some sort of fallback ish thing". Off by default until the replay-under-load bench proves it.
/// To try it, set `cmux.experiments` to `{"chat-load-coalesce":"on"}` in the pane's web inspector and reload.
export const chatLoadCoalesce = defineExperiment({
  id: "chat-load-coalesce",
  title: "Chat draws under load",
  description:
    "A page that misses frames draws the streaming chat at most every 100 ms instead of every frame. Look at whether the stream still reads as live under CPU load.",
  arms: {
    off: { label: "Every frame", description: "Today: one snapshot and one React commit per display frame." },
    on: {
      label: "Coalesced under load",
      description: "While snapshot frames come late, one snapshot per 100 ms; per frame again once they come on time.",
    },
  },
  defaultArm: "off",
});
