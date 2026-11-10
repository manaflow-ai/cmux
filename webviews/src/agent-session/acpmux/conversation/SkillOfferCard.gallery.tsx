// l10n-allow-file: gallery fixtures (sample drafts, prompts and errors), not shipped UI.
// The skill offer card (SkillOfferCard.tsx) in three looks. References: cmux-design-references
// `aside/web/human-approval-card` (enough source context to decide, one clear primary action),
// `codex/web/skills-library` and `codex/web/skill-selector` (a skill reads as a mono name and one
// line of when to use it), and the memory inbox card's hairline box, which this one matches.
//
// - compact (shipped): the question, the skill's name and when to use it, its SKILL.md behind
//   "Show steps", and Not now, Edit and Save. At rest it is about the memory card's height, so a
//   closing turn does not turn into a wall of Markdown, and the steps are one click away for anyone
//   who wants to read before saving (Edit shows them all too).
// - preview: the same head over the whole SKILL.md in a code block. Nothing is hidden, but the card
//   is 10 to 20 lines tall on every third chat, which is louder than an offer should be.
// - checklist: the numbered steps as a list and a chip per source chat. The chips explain where the
//   draft came from, but the prompts are long and cut short, they read as links that go nowhere,
//   and the commands under the steps are left out of what the person sees.
//
// Each look shows a live offer (Save, Edit and Not now settle after a short wait, as the daemon
// answers; its first Save fails with a name that exists, as acpmux refuses it), an offer built from
// recorded steps, the edit state, a failed save, a saved card's note and a declined card's note.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SkillOfferCard, type SkillCardLook } from "./SkillOfferCard";
import {
  settleSkillOffer,
  skillOfferFromRecord,
  skillRequestFailed,
  skillRequestStarted,
  type SkillOffer,
} from "./skillOffer";

const offer = (data: Record<string, unknown>) => skillOfferFromRecord(data)!;

const BODY = [
  "## Steps",
  "",
  "1. Install the web dependencies in webviews/ if node_modules is missing.",
  "2. Run the tests for the files you changed.",
  "3. Run the type check and the formatter check.",
  "4. Fix every failure before you report back.",
  "",
  "## Commands",
  "",
  "```sh",
  "cd webviews && bun install --frozen-lockfile",
  "bun test src/agent-session/acpmux/conversation/",
  "vp check --no-fmt --no-lint",
  "vp fmt --check",
  "```",
].join("\n");

const CHATS = [
  { sessionId: "chat-1", prompt: "Run the webview tests for the memory card and fix what fails." },
  { sessionId: "chat-2", prompt: "The composer tests are red on my branch, can you run them and fix it?" },
  { sessionId: "chat-3", prompt: "Run the agent pane tests and the type check before I push." },
];

const LIVE = offer({
  offerId: "live",
  name: "run-webview-tests",
  description: "Use when asked to run or fix the webview tests in this repository.",
  body: BODY,
  count: 3,
  chats: CHATS,
  drafted: "harness",
  harness: "claude",
});
const SHAPES = offer({
  offerId: "shapes",
  name: "rebuild-rust-daemon",
  description: "Use when the acpmux daemon needs a rebuild after a change in cmux-tui.",
  body: "## Steps\n\n1. Run the compile check on the fleet.\n2. Restart the dev daemon.\n\n## Commands\n\n- `cmux-ci compile-check --package acpmux`\n- `cmux live start --rust`",
  count: 4,
  chats: CHATS,
  drafted: "shapes",
});
const FAILED = skillRequestFailed(
  offer({ ...LIVE, offerId: "failed" }),
  "a skill named run-webview-tests already exists",
);
const SAVED = settleSkillOffer(offer({ ...LIVE, offerId: "saved" }), {
  offerId: "saved",
  action: "save",
  name: "run-webview-tests",
  path: ".claude/skills/run-webview-tests/SKILL.md",
});
const DISMISSED = settleSkillOffer(offer({ ...LIVE, offerId: "dismissed" }), {
  offerId: "dismissed",
  action: "dismiss",
});

/// An offer the gallery settles itself, after a wait like the daemon's write. The first Save of
/// the draft's own name fails, as acpmux refuses a name that exists.
function LiveCard({
  initial,
  look,
  startEditing,
}: {
  initial: SkillOffer;
  look: SkillCardLook;
  startEditing?: boolean;
}) {
  const [state, setState] = useState(initial);
  const [refused, setRefused] = useState(false);
  return (
    <SkillOfferCard
      offer={state}
      look={look}
      startEditing={startEditing}
      onResolve={(action, draft) => {
        setState((current) => skillRequestStarted(current, action));
        setTimeout(() => {
          if (action === "save" && draft?.name === initial.name && !refused) {
            setRefused(true);
            setState((current) => skillRequestFailed(current, `a skill named ${draft.name} already exists`));
            return;
          }
          setState((current) =>
            settleSkillOffer(current, {
              action,
              name: draft?.name,
              path: draft ? `.claude/skills/${draft.name}/SKILL.md` : undefined,
            }),
          );
        }, 350);
      }}
    />
  );
}

function SkillLooks({ look }: { look: SkillCardLook }) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 16, alignContent: "start" }}>
      <LiveCard initial={LIVE} look={look} />
      <LiveCard initial={SHAPES} look={look} />
      <LiveCard initial={offer({ ...LIVE, offerId: "editing" })} look={look} startEditing />
      <SkillOfferCard offer={FAILED} look={look} onResolve={() => {}} />
      <SkillOfferCard offer={SAVED} look={look} onResolve={() => {}} />
      <SkillOfferCard offer={DISMISSED} look={look} onResolve={() => {}} />
      <SkillOfferCard offer={LIVE} look={look} />
    </div>
  );
}

export default componentEntry<{ look: SkillCardLook }>({
  id: "agent-pane.skill-offer",
  title: "Skill offer card",
  area: "Agent pane",
  pane: true,
  height: 1400,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/SkillOfferCard.tsx"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./SkillOfferCard.gallery.css")]),
  load: async () => SkillLooks,
  variants: {
    compact: {
      note: "Chosen: name and when to use it, the steps behind Show steps; about the memory card's height, so the closing turn stays calm.",
      props: { look: "compact" },
    },
    preview: {
      note: "The whole SKILL.md in a code block; nothing hidden, but 10 to 20 lines on every third chat is louder than an offer should be.",
      props: { look: "preview" },
    },
    checklist: {
      note: "Numbered steps and a chip per source chat; the cut prompts read as dead links and the commands drop out of view.",
      props: { look: "checklist" },
    },
  },
});
