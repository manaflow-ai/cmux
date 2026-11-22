// l10n-allow-file: synthetic command names and descriptions for the gallery.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { SlashMenu } from "./SlashMenu";
import type { SlashMatch } from "./slashCommands";

const matches: SlashMatch[] = Array.from({ length: 40 }, (_, index) => ({
  command: { name: `review-${index}`, description: `Review step ${index}` },
  ranges: [],
}));

function SlashMenuGallery() {
  const [active, setActive] = useState(-1);
  return (
    <div className="acpmux-shell" style={{ height: "100%", position: "relative" }}>
      <div style={{ position: "absolute", bottom: 8, left: 16, right: 16 }}>
        <SlashMenu matches={matches} active={active} empty="No commands" onHover={setActive} onPick={() => undefined} />
      </div>
    </div>
  );
}

// Beyer composer outcome hints (composerOutcomeHints.experiment.ts): a Claude Code chat's real list,
// the top row highlighted, as the person sees it after typing "/".
const claudeMatches: SlashMatch[] = [
  { name: "compact", description: "Clear conversation history but keep a summary in context" },
  { name: "review", description: "Review a pull request" },
  { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" },
  { name: "security-review", description: "Complete a security review of the pending changes", source: "skill" },
  { name: "simplify", description: "Review changed code for reuse and simplification", source: "skill" },
  { name: "cost", description: "Show the total cost and duration of the current session" },
].map((command) => ({ command: command as SlashMatch["command"], ranges: [] }));

function OutcomeSlashMenuGallery({ arm }: { arm: string }) {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "composer-outcome-hints": arm };
  const [active, setActive] = useState(0);
  return (
    <div className="acpmux-shell" style={{ height: "100%", position: "relative" }}>
      <div style={{ position: "absolute", bottom: 8, left: 16, right: 16 }}>
        <SlashMenu
          matches={claudeMatches}
          active={active}
          empty="No commands"
          onHover={setActive}
          onPick={() => undefined}
        />
      </div>
    </div>
  );
}

function Gallery(props: { arm?: string }) {
  return props.arm ? <OutcomeSlashMenuGallery arm={props.arm} /> : <SlashMenuGallery />;
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
  load: async () => Gallery,
  variants: {
    overflowing: { props: {} },
    "outcome-hints-now": {
      note: "Today: bare rows; only the highlighted row says what it does.",
      props: { arm: "now" },
    },
    "outcome-hints-rows": {
      note: "Outcome hints (c): every row its one-line description, the highlighted row Return's keycap.",
      props: { arm: "outcomes" },
    },
  },
});
