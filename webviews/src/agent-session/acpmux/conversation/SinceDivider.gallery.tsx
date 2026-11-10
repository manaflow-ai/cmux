// l10n-allow-file: gallery fixtures (sample recaps and replies), not shipped UI.
// "New since you looked" (SinceDivider.tsx) in each view the viewer can pick (sinceView.ts), between
// the reply the person had seen and the turns that ended while they were away, with the recap made
// for that return on it, and Jump to new over the top. References: team chat apps' unread
// line (a hairline that ends in a filled New tag), the pane's accent for every color, and the
// glass of Jump to latest (cmux-next/live/transcript-jump-to-latest-glass-too-transparent).
import { componentEntry } from "../../../gallery/format";
import { SinceDivider, SinceJump } from "./SinceDivider";
import type { SinceViewPick } from "./sinceView";

const RECAP =
  "The parser in foo.rs now tolerates missing fields and its tests pass. Next: run the fuzz corpus and open the PR.";

function Reply({ text }: { text: string }) {
  return <p style={{ margin: 0, color: "var(--agent-text)", lineHeight: "20px" }}>{text}</p>;
}

function SinceViews({ view, recap = true, jump = false }: { view: SinceViewPick; recap?: boolean; jump?: boolean }) {
  return (
    <div className="acpmux-shell" style={{ position: "relative", padding: 16, display: "grid", gap: 16 }}>
      {jump && (
        <div className="acpmux-over-top" style={{ top: 0 }}>
          <SinceJump mark="gallery" turns={3} view={view} onJump={() => {}} />
        </div>
      )}
      <Reply text="I'll start by reading foo.rs to see how absent fields fail." />
      <SinceDivider
        since={{
          key: `gallery-${view}:41`,
          seq: 41,
          turns: 3,
          ...(recap && { recap: { key: `gallery-${view}`, text: RECAP, awayMs: 38 * 60_000 } }),
        }}
        onDismissRecap={() => {}}
        view={view}
      />
      <Reply text="Missing fields now default instead of failing; I added a test for each one." />
      <Reply text="The fuzz corpus ran clean for 10 minutes. The PR is ready for review." />
    </div>
  );
}

export default componentEntry<{ view: SinceViewPick; recap?: boolean; jump?: boolean }>({
  id: "agent-pane.since-divider",
  title: "New since you looked",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => SinceViews,
  variants: {
    expanded: {
      note: "Ships (the default): an accent hairline across the text column ending in a filled New tag, the turn count muted before it, the recap card under it. A click collapses it.",
      props: { view: "expanded" },
    },
    collapsed: {
      note: "Collapsed (a click on the line, or its right-click): the hairline and its New tag alone; the recap folds away.",
      props: { view: "collapsed" },
    },
    "no-recap": {
      note: "A chat with no recap (not Claude, or the recap is off): the line alone, expanded.",
      props: { view: "expanded", recap: false },
    },
    "jump-to-new": {
      note: "Jump to new, expanded: a glass bar on the text column with the line's words, its count and ×, which puts it away for this return.",
      props: { view: "expanded", jump: true },
    },
    "jump-to-new-collapsed": {
      note: "Jump to new, collapsed: a small glass tab holding the New tag.",
      props: { view: "collapsed", jump: true },
    },
    hidden: {
      note: "Hidden (its right-click's Hide): neither draws; the chat menu's Show New Since You Looked brings both back.",
      props: { view: "hidden", jump: true },
    },
  },
});
