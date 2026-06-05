import { t } from "./i18n.js";

export function createAppearancePreview({
  settings,
  themeLabel,
  accentLabel,
  contrastLabel,
  depthLabel,
  backgroundLabel,
  terminalFontLabel,
  terminalFontStack,
  terminalTheme,
  backgroundImage,
  backgroundReadability,
  backgroundSize,
  backgroundRepeat,
  backgroundPosition
}) {
  const panel = document.createElement("div");
  const hasVisibleBackground = Boolean(backgroundImage && backgroundImage !== "none" && Number(settings.backgroundOpacity) > 0);
  panel.className = `appearance-preview appearance-depth-${settings.interfaceDepth || "soft"} appearance-background-${settings.backgroundChromeMode || "soft"} appearance-effect-${settings.backgroundEffects || "flat"}`;
  panel.style.setProperty("--preview-background-image", backgroundImage || "none");
  panel.style.setProperty("--preview-background-opacity", String(Math.max(0, Math.min(0.42, Number(settings.backgroundOpacity) / 100 || 0))));
  panel.style.setProperty("--preview-background-readability-opacity", hasVisibleBackground ? backgroundReadability?.base || "0.16" : "0");
  panel.style.setProperty("--preview-background-tinted-opacity", hasVisibleBackground ? backgroundReadability?.tinted || "0.64" : "0");
  panel.style.setProperty("--preview-background-vignette-opacity", hasVisibleBackground ? backgroundReadability?.vignette || "0.78" : "0");
  panel.style.setProperty("--preview-background-size", backgroundSize || "cover");
  panel.style.setProperty("--preview-background-repeat", backgroundRepeat || "repeat");
  panel.style.setProperty("--preview-background-position", backgroundPosition || "center");
  panel.style.setProperty("--preview-terminal-background", terminalTheme.background);
  panel.style.setProperty("--preview-terminal-foreground", terminalTheme.foreground);
  panel.style.setProperty("--preview-terminal-cursor", terminalTheme.cursor);
  panel.style.setProperty("--preview-terminal-font", terminalFontStack);

  panel.innerHTML = `
    <div class="appearance-preview-frame" aria-hidden="true">
      <div class="appearance-preview-backdrop"></div>
      <div class="appearance-preview-sidebar">
        <span class="appearance-preview-brand">cm</span>
        <span></span>
        <span></span>
      </div>
      <div class="appearance-preview-main">
        <div class="appearance-preview-topbar">
          <span></span>
          <span></span>
          <span></span>
        </div>
        <div class="appearance-preview-tabs">
          <span class="is-active"></span>
          <span></span>
          <span></span>
        </div>
        <div class="appearance-preview-terminal">
          <span>PS C:\\app&gt; npm run dev</span>
          <span class="appearance-preview-good">renderer ready</span>
          <span>git status --short</span>
          <span class="appearance-preview-cursor"></span>
        </div>
      </div>
    </div>
    <div class="appearance-preview-summary">
      <span><b data-preview-label-theme></b><em data-preview-theme></em></span>
      <span><b data-preview-label-accent></b><em data-preview-accent></em></span>
      <span><b data-preview-label-contrast></b><em data-preview-contrast></em></span>
      <span><b data-preview-label-depth></b><em data-preview-depth></em></span>
      <span><b data-preview-label-background></b><em data-preview-background></em></span>
      <span><b data-preview-label-terminal></b><em data-preview-terminal></em></span>
    </div>
  `;

  panel.querySelector("[data-preview-label-theme]").textContent = t("appearance.theme");
  panel.querySelector("[data-preview-label-accent]").textContent = t("appearance.accent");
  panel.querySelector("[data-preview-label-contrast]").textContent = t("appearance.contrast", "Contrast");
  panel.querySelector("[data-preview-label-depth]").textContent = t("appearance.depth", "Depth");
  panel.querySelector("[data-preview-label-background]").textContent = t("appearance.background");
  panel.querySelector("[data-preview-label-terminal]").textContent = t("appearance.terminal");
  panel.querySelector("[data-preview-theme]").textContent = themeLabel;
  panel.querySelector("[data-preview-accent]").textContent = accentLabel;
  panel.querySelector("[data-preview-contrast]").textContent = contrastLabel;
  panel.querySelector("[data-preview-depth]").textContent = depthLabel;
  panel.querySelector("[data-preview-background]").textContent = backgroundLabel;
  panel.querySelector("[data-preview-terminal]").textContent = terminalFontLabel;
  return panel;
}
