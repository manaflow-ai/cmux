// A look's thinking dots in the agent chat (thinkingLook.ts `glyph`; Leo, 2026-11-19: "previously
// there was this thinking thing (this is claude code desktop) that i added in cmux nightly... we can
// add back it into our claude code desktop customization. we will also want to be adding it for that
// one's jump to bottom's animation too when it's thinking and stuff"). The scene player
// (apps/scene/choreographyGlyph.ts) draws it: one span per dot moved by `transform` only, on the
// page's one shared clock, which runs only while a glyph is on screen and the page is visible, and
// holds a still under Reduce Motion. The box is sized once from the document (`glyphExtent`), so no
// frame lays out. A new document remounts the glyph; a new trigger reaches the running player, which
// reads it when its phase ends. Decorative: the line's words and the button's label say the state.
import { useEffect, useMemo, useRef } from "react";
import type { Choreography } from "../../../apps/scene/choreography";
import { mountChoreographyGlyph } from "../../../apps/scene/choreographyGlyph";
import { sceneColor } from "../../../apps/scene/sceneStyle";
import { glyphExtent } from "./thinkingGlyphModel";
import "./ThinkingGlyph.css";

/** The document's `particle.color`: `accent` (the default) is the chat's own accent. */
function glyphColor(doc: Choreography): string {
  if (doc.color === "accent") return "var(--agent-accent)";
  return sceneColor(doc.color) ?? "var(--agent-accent)";
}

export function ThinkingGlyph({
  doc,
  trigger,
  size,
  className,
}: {
  doc: Choreography;
  trigger: string;
  /** Points a dot, over the document's `particle.size`. */
  size?: number;
  className: string;
}) {
  const pointRef = useRef<HTMLSpanElement>(null);
  const controls = useRef<ReturnType<typeof mountChoreographyGlyph> | null>(null);
  const triggerRef = useRef(trigger);
  // Declared before the mount effect, so a remount starts from this render's trigger.
  useEffect(() => {
    triggerRef.current = trigger;
  });
  const extent = useMemo(() => glyphExtent(doc, size), [doc, size]);

  useEffect(() => {
    const point = pointRef.current;
    if (!point) return;
    const mounted = mountChoreographyGlyph(
      point,
      doc,
      { trigger: triggerRef.current },
      { size, color: glyphColor(doc) },
    );
    controls.current = mounted;
    return () => {
      mounted.unmount();
      controls.current = null;
    };
  }, [doc, size]);

  useEffect(() => {
    controls.current?.setRequest({ trigger });
  }, [trigger]);

  return (
    <span
      className={`cv-glyph ${className}`}
      aria-hidden="true"
      style={{ width: `${extent.width}px`, height: `${extent.height}px` }}
    >
      <span ref={pointRef} className="cv-glyph__point" />
    </span>
  );
}
