// l10n-allow-file: public-safe gallery fixtures, not shipped copy.
// The Stashed chip in the quiet row (StashedChip.tsx). Three looks were drawn for it: the tray glyph
// with a count (picked: one icon column, the count in tabular figures, no word to translate or cut),
// the word with a count, and a dot on the mode chip. The empty state draws the same row as before, so
// the first stash opens the chip in place with nothing else moving.
import { componentEntry } from "../../../gallery/format";
import { ComposerFoot } from "../ComposerFoot";
import type { ComposerAttachment } from "../attachments";
import { StashedChip } from "./StashedChip";
import type { StashedDraft } from "./draftStash";

type Look = "glyph" | "word" | "dot";
type Props = { drafts: StashedDraft[]; look?: Look };

const image: ComposerAttachment = { id: "img", kind: "image", name: "shot.png", mimeType: "image/png", size: 10 };
const draft = (id: string, text: string, attachments: ComposerAttachment[] = []): StashedDraft => ({
  id,
  text,
  attachments,
  at: 0,
});
const three = [
  draft("c", "Refactor the settings store so each row reads from the schema, then add tests"),
  draft("b", "", [image]),
  draft("a", "Why does the sidebar flicker when a workspace closes?", [image]),
];

function Row({ drafts, look = "glyph" }: Props) {
  return (
    <div className="acpmux-composer" style={{ padding: 16 }}>
      <ComposerFoot>
        <span className="acpmux-access" style={{ marginInlineEnd: "auto" }}>
          Ask before edits
          {look === "dot" && drafts.length > 0 && <span aria-hidden="true"> •</span>}
        </span>
        {look === "glyph" && <StashedChip drafts={drafts} chat="demo" onRestore={() => undefined} />}
        {look === "word" && drafts.length > 0 && (
          <span className="acpmux-picker-button" style={{ color: "var(--agent-muted)" }}>
            Stashed {drafts.length}
          </span>
        )}
        <span className="acpmux-picker-button">Opus 5.5 Medium</span>
      </ComposerFoot>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.composer-stash",
  title: "Composer stash chip",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/composer/StashedChip.tsx#StashedChip"],
  styles: () => import("../styles.css"),
  load: async () => Row,
  widths: { narrow: 360, normal: 620 },
  height: 120,
  variants: {
    empty: { note: "Nothing stashed: the row as it was; the chip has no width and no focus.", props: { drafts: [] } },
    one: { note: "Picked look: the tray glyph and a count, after the mode.", props: { drafts: three.slice(0, 1) } },
    three: {
      note: "Three stashed drafts; the menu lists them newest first, ⌃S on the newest.",
      props: { drafts: three },
    },
    word: {
      note: "Rejected: the word takes room and cuts first in a narrow row.",
      props: { drafts: three, look: "word" },
    },
    dot: {
      note: "Rejected: a dot on the mode chip says nothing about what it is.",
      props: { drafts: three, look: "dot" },
    },
  },
});
