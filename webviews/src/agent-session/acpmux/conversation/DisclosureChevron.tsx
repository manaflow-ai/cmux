// The one disclosure chevron every transcript row draws right after its label's words: "Worked for
// 12s ›", "Working for 40s ›", a thought, a tool group ("Ran 2 commands ›"), a single call, a run of
// messages. One glyph size and one gap after the words on every row (conversation.css
// `.cv-disclosure-chevron`, --cv-chevron-gap), never parked at the line's far edge (Leo, 2026-11-25:
// "chevron spacing bad"). test/transcript-chevron-after-label.test.ts measures the shipped rows.
import { ChevronRight } from "./icons";

export function DisclosureChevron({
  open,
  look = "tool",
  reserved = false,
}: {
  open: boolean;
  /// `tool`: a tool row's chevron, shown on hover while closed; `worked`: the turn header's, always shown.
  look?: "tool" | "worked";
  /// Holds the chevron's slot unseen (a running turn's header, WorkingFor.tsx).
  reserved?: boolean;
}) {
  const part = look === "worked" ? "cv-worked__chevron" : "cv-tool__chevron";
  const state = open ? " is-open" : look === "tool" ? " is-hover" : "";
  return (
    <ChevronRight
      size={14}
      className={`cv-disclosure-chevron ${part} cv-rotor${state}${reserved ? " is-reserved" : ""}`}
    />
  );
}
