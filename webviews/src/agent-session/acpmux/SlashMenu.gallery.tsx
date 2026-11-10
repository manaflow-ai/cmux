// l10n-allow-file: synthetic command names and descriptions for the gallery.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { SlashMenu } from "./SlashMenu";
import type { SlashMatch } from "./slashCommands";

const matches: SlashMatch[] = Array.from({ length: 40 }, (_, index) => ({
  command: { name: `review-${index}`, description: `Review step ${index}` },
  ranges: [],
}));

/** `loading`: the chat's own commands are not read yet and nothing matched (`commandsPending`). */
function SlashMenuGallery({ loading = false }: { loading?: boolean }) {
  const [active, setActive] = useState(-1);
  return (
    <div className="acpmux-shell" style={{ height: "100%", position: "relative" }}>
      <div style={{ position: "absolute", bottom: 8, left: 16, right: 16 }}>
        <SlashMenu
          matches={loading ? [] : matches}
          active={active}
          empty={loading ? "Loading commands…" : "No commands"}
          onHover={setActive}
          onPick={() => undefined}
        />
      </div>
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.slash-menu",
  title: "Slash command scroll edges",
  area: "Composer",
  pane: true,
  height: 320,
  widths: { normal: 640 },
  styles: () => import("./styles.css"),
  covers: ["agent-session/acpmux/SlashMenu.tsx#SlashMenu"],
  load: async () => SlashMenuGallery,
  variants: {
    overflowing: { props: {} },
    // Typed before the agent's command list arrived: it says so instead of "No commands".
    "loading-commands": { props: { loading: true } },
  },
});
