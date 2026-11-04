// l10n-allow-file: gallery fixtures (subagent names), not shipped UI.
// A finished subagent's line (SubagentDoneLine.tsx) at the widths it meets: "Subagent finished:
// [name] ›   1m 20s". Leo, 2026-11-03, on a row whose chip was cut at about a third of the pane with
// a lone chevron at its far right: "this is pretty bad spacing and formatting" / "i thought we made
// this stuff smaller". The chip takes the room the row has and is cut only at the row's edge; the
// chevron sits right after it; the duration stays at the line's end. Three looks are compared: the
// chip taking the row (the pick), the chip capped at 60% of the line, and the base's 40% cap, which
// left a gap after the chip. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "./subagentFold";

type Look = "fill" | "cap60" | "before";
/** `pane`: the column's width in CSS px, for the narrow pane. */
type Props = { names: string[]; look?: Look; pane?: number; failed?: boolean };

const LONG =
  "Fix defaults-snapshot drift in the settings schema generator, its golden files, the docs page, the MDM profile export and every test that reads them";
const ERROR = "503: no non-exhausted claude accounts available after four retries on the capacity route, giving up";
const SHORT = "Explore";

const done = (name: string, index: number, failed = false): AcpmuxRow => {
  const agent: Subagent = {
    id: `agent-done-${index}`,
    parent: null,
    name,
    task: name,
    kind: "general-purpose",
    state: failed ? "failed" : "completed",
    ...(failed && { error: ERROR }),
    startedAt: minutesAgo(12),
    endedAt: minutesAgo(10.6),
    prompt: name,
  };
  return {
    id: `done-${index}`,
    version: 1,
    kind: "subagentDone" /* subagentRows.ts SUBAGENT_DONE */,
    at: agent.endedAt!,
    subagents: [agent],
  };
};

export default componentEntry<Props>({
  id: "agent-pane.subagent-done",
  title: "Subagent finished line",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-subagent-done-gallery]" }],
  covers: ["agent-session/acpmux/subagents/SubagentDoneLine.tsx#SubagentDoneLine"],
  load: async () => {
    const { SubagentDoneLine } = await import("./SubagentDoneLine");
    const { SubagentNavContext } = await import("./SubagentGroup");
    return function GallerySubagentDone({ names, look = "fill", pane, failed }: Props) {
      return (
        <SubagentNavContext.Provider value={() => undefined}>
          <main
            className="acpmux-shell subagent-done-gallery"
            data-subagent-done-gallery
            data-look={look}
            style={{ padding: "16px", flexDirection: "column", gap: "0", ...(pane ? { width: `${pane}px` } : {}) }}
          >
            {names.map((name, index) => (
              <section key={index} className="acpmux-row">
                <SubagentDoneLine row={done(name, index, failed)} />
              </section>
            ))}
          </main>
        </SubagentNavContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./subagents.css"),
      import("./SubagentDoneLine.gallery.css"),
    ]),
  variants: {
    "long-title": {
      note: "The pick, Leo's row: a long name takes the row and is cut with an ellipsis at its edge; the chevron right after the chip, the duration at the line's end.",
      props: { names: [LONG] },
    },
    "short-title": {
      note: "A short name: the chip as wide as its words, the chevron right after it.",
      props: { names: [SHORT, "Push relay"] },
    },
    narrow: {
      note: "A 320px pane: the chip is cut first; the words before it, the chevron and the duration stay.",
      props: { names: [LONG, SHORT], pane: 320 },
    },
    "failed-long-error": {
      note: "A failure with a long error, on the failed-line grid: the reason is cut first, the title keeps its words.",
      props: { names: ["Push relay for GCP lane bundles"], failed: true },
    },
    "cap-60": {
      note: "Version B: the chip capped at 60% of the line. Leaves room on a wide pane, cuts names that would fit.",
      props: { names: [LONG, SHORT], look: "cap60" },
    },
    before: {
      note: "Before: the base's 40% cap, a cut name and an empty gap before the chevron, Leo's capture.",
      props: { names: [LONG, SHORT], look: "before" },
    },
  },
});
