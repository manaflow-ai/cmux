/** Returns whether the host has explicitly disabled agent motion. */
export function isAgentMotionOff(): boolean {
  return typeof document !== "undefined" && document.documentElement.dataset.agentMotion === "off";
}
