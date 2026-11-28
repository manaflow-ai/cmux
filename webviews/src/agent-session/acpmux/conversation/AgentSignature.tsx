// The agent dot signature before the running line's words (agentSignatureModel.ts): the chat's dots in
// its variant's accent, about 1em. Each dot drifts on a small circle, radius 0.04 * drift of the box,
// starting at its own phase (a still rotation of its spot, so no per-dot duration); only while the line
// is shown, and never under Reduce Motion, cmux motion off or reduced, agent motion off or the static
// status look (conversation.css `cv-signature`). Plain boxes, not an icon: the dots are data.
import type { CSSProperties } from "react";
import type { SignatureGlyph } from "./agentSignatureModel";

const percent = (unit: number) => `${unit * 100}%`;

export function AgentSignature({ glyph }: { glyph: SignatureGlyph }) {
  const drift = 0.04 * Math.max(0, glyph.drift);
  return (
    <span
      className="cv-signature"
      aria-hidden="true"
      data-variant={glyph.variant}
      style={{ "--cv-signature-drift": drift, color: glyph.accent } as CSSProperties}
    >
      {glyph.dots.map((dot, index) => (
        <span
          key={index}
          className="cv-signature__at"
          style={{
            left: percent(dot.x - dot.r),
            top: percent(dot.y - dot.r),
            width: percent(dot.r * 2),
            height: percent(dot.r * 2),
            rotate: `${(((dot.phase % 1) + 1) % 1) * 360}deg`,
          }}
        >
          <span className="cv-signature__dot" />
        </span>
      ))}
    </span>
  );
}
