// l10n-allow-file: gallery fixtures, not shipped UI.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../../gallery/format";

export default componentEntry<{ enabled: boolean }>({
  id: "agent-pane.copy-turn",
  title: "Copy a chat turn",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 120,
  covers: ["agent-session/acpmux/conversation/icons.tsx#CopyTurn"],
  load: async () => {
    const { TurnFooter } = await import("./TurnRows");
    const { configureLabs } = await import("../labs");
    return function CopyTurnGallery({ enabled }) {
      useLayoutEffect(() => {
        configureLabs({ labs: { copyTurn: enabled } });
        return () => configureLabs(undefined);
      }, [enabled]);
      return (
        <TurnFooter
          row={{
            id: "gallery-copy-turn",
            kind: "turnSummary",
            version: 1,
            at: 1_580_639_660_000,
            folded: true,
            turnPrompt: "Check the retry policy.",
            text: "The retry policy passes its focused checks.",
            status: "completed",
          }}
        />
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    enabled: { props: { enabled: true } },
    "lab-off": { props: { enabled: false } },
  },
});
