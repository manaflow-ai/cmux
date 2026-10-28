/** Whether muted inline media previews may start from pointer hover. */
export function mediaPreviewAllowed(root?: HTMLElement): boolean {
  const element = root ?? (typeof document === "undefined" ? undefined : document.documentElement);
  if (!element) return true;
  if (
    element.dataset.agentMotion === "off" ||
    element.dataset.agentMotion === "reduced" ||
    element.dataset.cmuxMotion === "off" ||
    element.dataset.cmuxMotion === "reduced" ||
    element.dataset.statusIndicators === "static"
  )
    return false;
  return !(typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches);
}
