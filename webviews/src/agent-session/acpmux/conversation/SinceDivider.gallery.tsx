// l10n-allow-file: gallery fixtures (sample recaps and replies), not shipped UI.
// "New since you looked" (SinceDivider.tsx) in three looks, each between the reply the person had
// seen and the turns that ended while they were away, with the recap made for that return on it, and
// Jump to new over the top. References: the unread blue of the sidebar's status dots
// (cmux-design-references cmux/live/sidebar-status-dot-colors) and the glass of Jump to latest
// (cmux-next/live/transcript-jump-to-latest-glass-too-transparent).
import { componentEntry } from "../../../gallery/format";
import { SinceDivider, SinceJump, type SinceLook } from "./SinceDivider";

const RECAP =
  "The parser in foo.rs now tolerates missing fields and its tests pass. Next: run the fuzz corpus and open the PR.";

function Reply({ text }: { text: string }) {
  return <p style={{ margin: 0, color: "var(--agent-text)", lineHeight: "20px" }}>{text}</p>;
}

function SinceLooks({ look, recap = true, jump = false }: { look: SinceLook; recap?: boolean; jump?: boolean }) {
  return (
    <div className="acpmux-shell" style={{ position: "relative", padding: 16, display: "grid", gap: 16 }}>
      {jump && (
        <div className="acpmux-over-top" style={{ top: 0 }}>
          <SinceJump mark="gallery" onJump={() => {}} />
        </div>
      )}
      <Reply text="I'll start by reading foo.rs to see how absent fields fail." />
      <SinceDivider
        since={{
          key: `gallery-${look}:41`,
          seq: 41,
          turns: 3,
          ...(recap && { recap: { key: `gallery-${look}`, text: RECAP, awayMs: 38 * 60_000 } }),
        }}
        onDismissRecap={() => {}}
        look={look}
      />
      <Reply text="Missing fields now default instead of failing; I added a test for each one." />
      <Reply text="The fuzz corpus ran clean for 10 minutes. The PR is ready for review." />
    </div>
  );
}

export default componentEntry<{ look: SinceLook; recap?: boolean; jump?: boolean }>({
  id: "agent-pane.since-divider",
  title: "New since you looked",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => SinceLooks,
  variants: {
    lead: {
      note: "Chosen: the words start on the text column and an unread-blue hairline runs on; reads first, like a heading, and the recap card sits under it.",
      props: { look: "lead" },
    },
    center: {
      note: "The words centered on the hairline; symmetric but floats off the text column the rows read from.",
      props: { look: "center" },
    },
    end: {
      note: "The hairline first and the words at its end; the quietest, but the eye meets the line before the words.",
      props: { look: "end" },
    },
    "no-recap": {
      note: "A chat with no recap (not Claude, or the recap is off): the line alone.",
      props: { look: "lead", recap: false },
    },
    "jump-to-new": {
      note: "Jump to new over the transcript's top while the line is out of view.",
      props: { look: "lead", jump: true },
    },
  },
});
