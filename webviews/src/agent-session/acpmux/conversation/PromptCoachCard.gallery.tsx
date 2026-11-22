// l10n-allow-file: gallery fixtures (sample prompts and rewrites), not shipped UI.
// The prompt coach card (PromptCoachCard.tsx) in three looks: card (shipped: the recap's and memory
// card's hairline box, the rewrite in a tinted prompt block), rule (a left rule like a quote) and
// compact (one line until opened). Each look shows a short rewrite and a long one that scrolls past
// eight lines; a read-only state shows the card with Copy and no ×. Copy goes to a stand-in here.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { PromptCoachCard, type PromptCoachLook } from "./PromptCoachCard";
import type { PromptCoach } from "./promptCoach";

const SHORT: PromptCoach = {
  coachId: "gallery-short",
  sessionId: "gallery-short",
  firstPrompt: "Add a dark mode toggle.",
  rewrite:
    "Add a dark mode toggle in Settings > Appearance (not the header). It follows the system until someone sets it, and uses the existing theme tokens: no new colours.",
  corrections: 3,
};
const LONG: PromptCoach = {
  coachId: "gallery-long",
  sessionId: "gallery-long",
  firstPrompt: "Run the webview tests.",
  rewrite: [
    "Run the webview tests for the agent chat and fix what fails.",
    "",
    "- Use bun, never npm, and run from webviews/, not the repository root.",
    "- Only the files under src/agent-session/acpmux/conversation; leave the gallery alone.",
    "- A test that fails the same way on the base branch is not ours: note it and move on.",
    "- Don't add snapshot tests; assert on the DOM the way the neighbouring tests do.",
    "- Run scripts/web-lint.sh before you say it is done, and fix every error it names.",
    "- When a fix needs a change in direct.ts, keep it to the record handling.",
    "- Keep each fix in its own commit with the failing test first.",
    "- Tell me which tests you ran and which you only read.",
  ].join("\n"),
  corrections: 5,
};

/// Copy in the gallery: always "copied", nothing on the clipboard.
const galleryCopy = async () => true;

function Card({ coach, look, readOnly }: { coach: PromptCoach; look: PromptCoachLook; readOnly: boolean }) {
  const [shown, setShown] = useState(true);
  if (!shown) return null;
  return (
    <PromptCoachCard
      coach={coach}
      look={look}
      copy={galleryCopy}
      onDismiss={readOnly ? undefined : () => setShown(false)}
    />
  );
}

function CoachLooks({ look, readOnly = false }: { look: PromptCoachLook; readOnly?: boolean }) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 16, alignContent: "start" }}>
      <Card coach={SHORT} look={look} readOnly={readOnly} />
      <Card coach={LONG} look={look} readOnly={readOnly} />
    </div>
  );
}

export default componentEntry<{ look: PromptCoachLook; readOnly?: boolean }>({
  id: "agent-pane.prompt-coach",
  title: "Prompt coach card",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/PromptCoachCard.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => CoachLooks,
  variants: {
    card: {
      note: "Chosen: the hairline card the recap and memory cards use, the rewrite shown at once in a tinted prompt block, Copy and × on the label line. The rewrite is the point, so nothing hides it.",
      props: { look: "card" },
    },
    rule: {
      note: "A left rule like a quote, no box; quieter, but the rewrite reads as more of the agent's own text.",
      props: { look: "rule" },
    },
    compact: {
      note: "One line until Show more; the least room, but the rewrite hides behind a click and the row grows when it opens.",
      props: { look: "compact" },
    },
    "read-only": {
      note: "A replay or a read-only subagent transcript: Copy still works, no ×.",
      props: { look: "card", readOnly: true },
    },
  },
});
