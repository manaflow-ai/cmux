export function createAppearancePreview({
  settings,
  themeLabel,
  accentLabel,
  backgroundLabel,
  terminalFontLabel,
  terminalFontStack,
  terminalTheme,
  backgroundImage
}) {
  const panel = document.createElement("div");
  panel.className = "appearance-preview";
  panel.style.setProperty("--preview-background-image", backgroundImage || "none");
  panel.style.setProperty("--preview-background-opacity", String(Math.max(0, Math.min(0.42, Number(settings.backgroundOpacity) / 100 || 0))));
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
      <span><b>Theme</b><em data-preview-theme></em></span>
      <span><b>Accent</b><em data-preview-accent></em></span>
      <span><b>Background</b><em data-preview-background></em></span>
      <span><b>Terminal</b><em data-preview-terminal></em></span>
    </div>
  `;

  panel.querySelector("[data-preview-theme]").textContent = themeLabel;
  panel.querySelector("[data-preview-accent]").textContent = accentLabel;
  panel.querySelector("[data-preview-background]").textContent = backgroundLabel;
  panel.querySelector("[data-preview-terminal]").textContent = terminalFontLabel;
  return panel;
}
