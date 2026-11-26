import { useEffect, useMemo, useRef } from "react";
import { parseChoreography, type ChoreoRequest } from "./choreography";
import { mountChoreographyGlyph } from "./choreographyGlyph";
import { sceneColor, sceneNumber } from "./sceneStyle";
import type { SceneNode } from "./store";

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/** The choreography of a `Particles` node, or null when it has none the player can read. */
export function nodeChoreography(node: SceneNode) {
  return node.props.choreography === undefined ? null : parseChoreography(node.props.choreography);
}

/**
 * `Particles {choreography}`: the glyph centred in the node's frame (choreographyGlyph.ts). A new
 * document remounts the glyph; `trigger` and `phase` reach the running player, which reads them when
 * its phase ends; `size` and `colors[0]` override the document's particle size and color.
 */
export function SceneChoreography({ node }: { node: SceneNode }) {
  const hostRef = useRef<HTMLSpanElement>(null);
  const controls = useRef<ReturnType<typeof mountChoreographyGlyph> | null>(null);
  const docKey = JSON.stringify(node.props.choreography ?? null);
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- `docKey` is the document's value; a new object with the same document changes nothing
  const doc = useMemo(() => parseChoreography(node.props.choreography), [docKey]);
  const request: ChoreoRequest = { trigger: text(node.props.trigger), phase: text(node.props.phase) };
  const size = sceneNumber(node.props.size);
  const colors = node.props.colors;
  const color = sceneColor(Array.isArray(colors) ? colors[0] : undefined) ?? sceneColor(doc?.color);
  const requestRef = useRef(request);
  // Declared before the mount effect, so a remount starts from this render's request.
  useEffect(() => {
    requestRef.current = request;
  });

  useEffect(() => {
    const host = hostRef.current;
    if (!host || !doc) return;
    const mounted = mountChoreographyGlyph(host, doc, requestRef.current, { size, color });
    controls.current = mounted;
    return () => {
      mounted.unmount();
      controls.current = null;
    };
  }, [doc, size, color]);

  useEffect(() => {
    controls.current?.setRequest({ trigger: request.trigger, phase: request.phase });
  }, [request.trigger, request.phase]);

  return <span ref={hostRef} className="cmux-app-scene-choreography" aria-hidden="true" />;
}
