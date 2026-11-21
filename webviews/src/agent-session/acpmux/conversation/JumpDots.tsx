// Jump to latest's working dots, a look's opt-in (thinkingLook.ts `jumpButton: "dots"`; Leo, 2026-11-19:
// "we will also want to be adding it for that one's jump to bottom's animation too when it's thinking
// and stuff"). As Claude's desktop app draws its scroll-to-bottom button while it works: three dots in
// the theme accent trade size between the middle and the ends, the ends spreading while they are big
// (JumpDots.css). Decorative: the button's label already says the agent works.
import "./JumpDots.css";

export type DotMotion = "thinking" | "search" | "square";

export function activityDotMotion(kind?: string): DotMotion {
  switch (kind) {
    case "search":
      return "search";
    case "read":
    case "execute":
      return "square";
    default:
      return "thinking";
  }
}

export function JumpDots({ motion = "thinking", inline = false }: { motion?: DotMotion; inline?: boolean }) {
  return (
    <span className="cv-jump-dots" data-motion={motion} data-inline={inline || undefined} aria-hidden="true">
      <span className="cv-jump-dots__dot" data-dot="start" />
      <span className="cv-jump-dots__dot" data-dot="middle" />
      <span className="cv-jump-dots__dot" data-dot="end" />
      {motion === "square" && <span className="cv-jump-dots__dot" data-dot="fourth" />}
    </span>
  );
}
