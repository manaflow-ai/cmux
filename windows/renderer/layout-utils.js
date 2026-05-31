export const paneLayoutPercentMin = 1;
export const paneLayoutPercentMax = 99;

export function clampPaneLayoutPercent(value) {
  const percent = Math.round(Number(value) || 0);
  return Math.min(paneLayoutPercentMax, Math.max(paneLayoutPercentMin, percent));
}

export function paneLayoutWeightsByActivePercent(panels, activePanelId, percent, scale) {
  if (!Array.isArray(panels) || panels.length <= 1 || !activePanelId) return new Map();
  if (!panels.some((panel) => panel.id === activePanelId)) return new Map();
  const layoutScale = Math.max(panels.length, Math.round(Number(scale) || panels.length));
  const otherPanels = panels.filter((panel) => panel.id !== activePanelId);
  const activeWeight = Math.min(
    layoutScale - otherPanels.length,
    Math.max(1, Math.round((clampPaneLayoutPercent(percent) / 100) * layoutScale))
  );
  const remaining = layoutScale - activeWeight;
  const otherWeight = Math.max(1, Math.floor(remaining / Math.max(1, otherPanels.length)));
  let assignedOther = 0;
  const weights = new Map();
  for (const panel of panels) {
    if (panel.id === activePanelId) {
      weights.set(panel.id, activeWeight);
      continue;
    }
    const isLastOther = assignedOther === otherPanels.length - 1;
    weights.set(panel.id, isLastOther ? Math.max(1, remaining - otherWeight * assignedOther) : otherWeight);
    assignedOther += 1;
  }
  return weights;
}

export function paneLayoutPercentFromWeights(weights, activePanelId, fallbackPercent) {
  const fallback = clampPaneLayoutPercent(fallbackPercent);
  if (!(weights instanceof Map) || !activePanelId || !weights.has(activePanelId)) return fallback;
  let total = 0;
  for (const weight of weights.values()) total += Math.max(0, Number(weight) || 0);
  if (!total) return fallback;
  return clampPaneLayoutPercent((Math.max(0, Number(weights.get(activePanelId)) || 0) / total) * 100);
}
