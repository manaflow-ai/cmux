import {
  setTextIfChanged,
  toggleClassIfChanged
} from "./dom-utils.js";
import { normalizeSettingsQuery } from "./settings-search.js";

export function createPerformanceOverviewPanel({
  createActionButton,
  model,
  onBalanced,
  onSearchChange,
  onTune
}) {
  const panel = document.createElement("div");
  panel.className = "performance-overview";
  panel.dataset.performanceOverview = "true";
  panel.innerHTML = `
    <div class="performance-overview-head">
      <span class="performance-overview-status" aria-hidden="true"></span>
      <span class="performance-overview-copy">
        <span class="performance-overview-title"></span>
        <span class="performance-overview-subtitle"></span>
      </span>
    </div>
    <div class="performance-overview-next" data-performance-overview-next>
      <span class="performance-overview-next-kicker" data-performance-overview-next-kicker></span>
      <span class="performance-overview-next-copy">
        <b data-performance-overview-next-title></b>
        <em data-performance-overview-next-body></em>
      </span>
      <span class="performance-overview-next-meta" data-performance-overview-next-meta></span>
    </div>
    <div class="performance-overview-grid">
      <span><b>Guard</b><em data-performance-overview-value="guard"></em></span>
      <span><b>Health</b><em data-performance-overview-value="health"></em></span>
      <span><b>Render</b><em data-performance-overview-value="render"></em></span>
      <span><b>Output</b><em data-performance-overview-value="output"></em></span>
      <span><b>Shell</b><em data-performance-overview-value="shell"></em></span>
      <span><b>Pane add</b><em data-performance-overview-value="paneAdd"></em></span>
      <span><b>Startup</b><em data-performance-overview-value="startup"></em></span>
      <span><b>Paused</b><em data-performance-overview-value="paused"></em></span>
      <span><b>Browsers</b><em data-performance-overview-value="browsers"></em></span>
    </div>
    <div class="settings-actions performance-overview-actions"></div>
  `;
  panel.querySelector(".performance-overview-actions").append(
    createActionButton("Tune now", onTune, "primary", "performance tune optimize lag speed"),
    createActionButton("Balanced", onBalanced, "", "balanced preset restore performance normal")
  );
  refreshPerformanceOverviewPanel(panel, model, { onSearchChange });
  return panel;
}

export function refreshPerformanceOverviewPanel(panel, model, options = {}) {
  if (!panel || !model) return false;
  toggleClassIfChanged(panel, "is-tuned", model.status === "tuned");
  toggleClassIfChanged(panel, "is-warning", model.status === "warning");
  toggleClassIfChanged(panel, "is-watching", model.status === "watching");
  toggleClassIfChanged(panel, "is-steady", model.status === "steady");
  toggleClassIfChanged(panel, "has-next-fix", Boolean(model.nextFixActive));
  const modelSearch = Object.values(model).join(" ");
  const search = normalizeSettingsQuery(`performance overview speed lag health fixes guard startup browser webview inactive suspended ${modelSearch}`);
  let changed = false;
  if (panel.dataset.settingsSearch !== search) {
    panel.dataset.settingsSearch = search;
    options.onSearchChange?.(panel, search);
    changed = true;
  }
  changed = setTextIfChanged(panel.querySelector(".performance-overview-title"), model.title) || changed;
  changed = setTextIfChanged(panel.querySelector(".performance-overview-subtitle"), model.reason) || changed;
  changed = setTextIfChanged(panel.querySelector("[data-performance-overview-next-kicker]"), model.nextFixKicker || "Next fix") || changed;
  changed = setTextIfChanged(panel.querySelector("[data-performance-overview-next-title]"), model.nextFixTitle || "Health ready") || changed;
  changed = setTextIfChanged(panel.querySelector("[data-performance-overview-next-body]"), model.nextFixBody || "No performance health fixes are pending.") || changed;
  changed = setTextIfChanged(panel.querySelector("[data-performance-overview-next-meta]"), model.nextFixMeta || "Ready") || changed;
  for (const [key, value] of Object.entries(model)) {
    const node = panel.querySelector(`[data-performance-overview-value="${key}"]`);
    if (node) changed = setTextIfChanged(node, value) || changed;
  }
  return changed;
}
