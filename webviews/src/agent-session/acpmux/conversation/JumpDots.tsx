// A look's working dots (thinkingLook.ts `jumpButton: "dots"`; Leo, 2026-11-19: "we will also want to be
// adding it for that one's jump to bottom's animation too when it's thinking and stuff"), on Jump to latest
// and before the live line's words. As Claude's desktop app draws them while it works: three dots in the
// theme accent that keep changing shape, a big middle, then big spread ends, then even (JumpDots.css).
// Decorative: the button's label and the line's words already say the agent works.
import "./JumpDots.css";

export function JumpDots({ inline = false }: { inline?: boolean }) {
  return (
    <span className="cv-jump-dots" data-inline={inline || undefined} aria-hidden="true">
      <span className="cv-jump-dots__dot" data-dot="start" />
      <span className="cv-jump-dots__dot" data-dot="middle" />
      <span className="cv-jump-dots__dot" data-dot="end" />
    </span>
  );
}
