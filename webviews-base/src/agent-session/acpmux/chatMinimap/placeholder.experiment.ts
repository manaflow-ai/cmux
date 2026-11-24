// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the VS Code Minimap (ChatMinimap.tsx) draws over a reply while it streams. The minimap is
/// frozen then: no redraw or view-box move per token. Leo (2026-10-26): "Just don't have it do anything
/// when a reply is streaming ... you could just put skeletons or some other sort of placeholder ...
/// You can even do, like, a cute shimmer effect." The block is sized once when the reply starts and
/// goes when it ends, when the minimap draws again. A shimmer runs only while the block exists, and
/// never under Reduce Motion (chatMinimap.css), where it is the plain skeleton. Dogfood switches from
/// `cmux.experiments`: {"chat-minimap-placeholder":"dotted"}.
export const chatMinimapPlaceholder = defineExperiment({
  id: "chat-minimap-placeholder",
  title: "Chat minimap streaming placeholder",
  description: "What the VS Code Minimap shows over a reply while it streams, instead of following each token.",
  arms: {
    skeleton: { label: "Skeleton", description: "A flat grey block where the reply is." },
    shimmer: { label: "Shimmer", description: "The grey block with a soft light band sweeping down it every 1.6 s." },
    dotted: { label: "Dotted", description: "A dotted outline around the reply's place, empty inside." },
    lines: { label: "Ghost lines", description: "Faint text-like lines where the reply is, as the map draws a reply." },
  },
  defaultArm: "shimmer",
});
