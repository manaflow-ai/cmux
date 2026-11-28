import { parseChoreography } from "./choreography";
import type { SceneNode } from "./store";

/** The choreography of a `Particles` node, or null when it has none the player can read. */
export function nodeChoreography(node: SceneNode) {
  return node.props.choreography === undefined ? null : parseChoreography(node.props.choreography);
}
