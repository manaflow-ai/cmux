/**
 * Returns whether the host explicitly disabled animation for the agent pane.
 *
 * `prefers-reduced-motion` is a separate, softer policy: the pane keeps short crossfades there.
 * The host's all-zero motion policy is the only state that must prevent Web Animations API work
 * from being scheduled at all.
 */
export function isAgentMotionOff(): boolean {
  return typeof document !== "undefined" && document.documentElement.dataset.agentMotion === "off";
}
