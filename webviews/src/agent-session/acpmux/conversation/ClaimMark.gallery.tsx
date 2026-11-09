// l10n-allow-file: deterministic gallery fixtures, not shipped UI.
// Claim checks (design/claim-checks.md): one reply per fixture turn, drawn in each of the three looks.
import { componentEntry } from "../../../gallery/format";
import type { ClaimCheck } from "../model";
import { ClaimLookContext, type ClaimLook } from "./ClaimMark";
import { Markdown } from "./Markdown";
import { TurnActionsContext } from "./turnActions";

type Turn = { title: string; reply: string; claims: ClaimCheck[] };

const TURNS: Turn[] = [
  {
    title: "A true claim",
    reply: "Fixed the off-by-one in the pager. All tests pass.",
    claims: [{ text: "All tests pass", kind: "tests", verdict: "backed", toolCallId: "t1", command: "cargo test -p acpmux" }],
  },
  {
    title: "A false claim",
    reply: "Moved the import and the build succeeds now.",
    claims: [{ text: "the build succeeds", kind: "build", verdict: "failed", toolCallId: "b1", command: "bun run build" }],
  },
  {
    title: "A claim with no run",
    reply: "Renamed the helper everywhere; lint is clean.",
    claims: [{ text: "lint is clean", kind: "lint", verdict: "none" }],
  },
  {
    title: "A claim whose last run failed",
    reply: "Tests pass and typecheck passes.",
    claims: [
      { text: "Tests pass", kind: "tests", verdict: "failed", toolCallId: "t3", command: "pytest -x" },
      { text: "typecheck passes", kind: "typecheck", verdict: "backed", toolCallId: "c1", command: "bunx tsc --noEmit" },
    ],
  },
];

function ClaimChecksGallery({ look }: { look: ClaimLook }) {
  return (
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <ClaimLookContext.Provider value={look}>
        <div style={{ display: "grid", gap: 16, padding: 16 }}>
          {TURNS.map((turn) => (
            <section key={turn.title}>
              <div style={{ opacity: 0.6, fontSize: "var(--text-caption, 11px)" }}>{turn.title}</div>
              <Markdown claims={turn.claims}>{turn.reply}</Markdown>
            </section>
          ))}
        </div>
      </ClaimLookContext.Provider>
    </TurnActionsContext.Provider>
  );
}

export default componentEntry<{ look: ClaimLook }>({
  id: "agent-pane.claim-checks",
  title: "Claim checks",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 420, normal: 680, wide: 960 },
  covers: ["agent-session/acpmux/conversation/ClaimMark.tsx#ClaimMark"],
  styles: () => import("../styles.css"),
  load: async () => ClaimChecksGallery,
  variants: {
    underline: {
      note: "Selected. Only the phrase's underline takes the verdict's color, so no line moves when checks arrive.",
      props: { look: "underline" },
    },
    glyph: {
      note: "A check or cross after the phrase: easier to scan, but each mark widens its line at turn end.",
      props: { look: "glyph" },
    },
    chip: {
      note: "A pill that names the command: the most detail, but loud, and it wraps lines in a narrow pane.",
      props: { look: "chip" },
    },
  },
});
