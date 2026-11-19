// The agent dot signature before the running line's words (agentSignatureModel.ts): the chat's dots in
// its variant's accent at 0.85, about 1em. Each dot drifts on a small circle, radius 0.04 * drift of
// the box, offset by its own phase; only while the line is shown, and never under Reduce Motion,
// cmux motion off or reduced, agent motion off or the static status look (conversation.css
// `cv-signature`).
import type { CSSProperties } from "react";
import type { SignatureGlyph } from "./agentSignatureModel";

/// The glyph's box in SVG units; dots and drift are fractions of it.
const BOX = 100;
/// One drift loop, in seconds.
const LOOP_S = 4;

export function AgentSignature({ glyph }: { glyph: SignatureGlyph }) {
  const drift = 0.04 * Math.max(0, glyph.drift) * BOX;
  return (
    <svg
      className="cv-signature"
      viewBox={`0 0 ${BOX} ${BOX}`}
      aria-hidden="true"
      focusable="false"
      data-variant={glyph.variant}
      style={{ "--cv-signature-drift": `${drift}px` } as CSSProperties}
    >
      {glyph.dots.map((dot, index) => (
        <circle
          key={index}
          className="cv-signature__dot"
          cx={dot.x * BOX}
          cy={dot.y * BOX}
          r={dot.r * BOX}
          fill={glyph.accent}
          fillOpacity={0.85}
          style={{ animationDelay: `${-(((dot.phase % 1) + 1) % 1) * LOOP_S}s` }}
        />
      ))}
    </svg>
  );
}
