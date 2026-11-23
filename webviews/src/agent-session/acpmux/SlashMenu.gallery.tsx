// l10n-allow-file: synthetic command names and descriptions for the gallery.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { setHintsRevealed } from "./composerOutcomeHintsModel";
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
        <SlashMenu
          query=""
          matches={matches}
          active={active}
          empty="No commands"
          onHover={setActive}
          onPick={() => undefined}
        />
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

function OutcomeSlashMenuGallery({ arm, reveal, query = "" }: { arm: string; reveal?: boolean; query?: string }) {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "composer-outcome-hints": arm };
  // The `hint` arm with its "?" pressed (composerOutcomeHintsModel.ts).
  setHintsRevealed(reveal === true);
  const [active, setActive] = useState(0);
  return (
    <div className="acpmux-shell" style={{ height: "100%", position: "relative" }}>
      <div style={{ position: "absolute", bottom: 8, left: 16, right: 16 }}>
        <SlashMenu
          query={query}
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

function Gallery(props: { arm?: string; reveal?: boolean; query?: string }) {
  return props.arm ? (
    <OutcomeSlashMenuGallery arm={props.arm} reveal={props.reveal} query={props.query} />
  ) : (
    <SlashMenuGallery />
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
    // Leo 2026-11-22 09:50Z: "this is good as tips": the same rows, on demand only.
    "outcome-hints-hint-shown": {
      note: "Tip (b): the composer's ? pressed: every row its description, the highlighted row Return's keycap.",
      props: { arm: "hint", reveal: true },
    },
    "outcome-hints-run": {
      note: "On-demand tip on a complete command: Return runs it, Tab completes it without sending.",
      props: { arm: "hint", reveal: true, query: "compact" },
    },
    "outcome-hints-option-held": {
      note: "Tip (c): Option held, as the harness updates list shows its versions: the same rows until it is let go.",
      props: { arm: "option" },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        view.dispatchEvent(new view.KeyboardEvent("keydown", { key: "Alt", altKey: true }));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-slash-keycap") !== null);
      },
    },
  },
});
