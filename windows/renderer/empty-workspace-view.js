import {
  replaceChildrenIfChanged,
  setAttributeIfChanged,
  setDatasetIfChanged,
  setDisabledIfChanged,
  setTextIfChanged,
  setTitleIfChanged,
  toggleClassIfChanged
} from "./dom-utils.js";

function createEmptyWorkspaceLogo() {
  const logo = document.createElement("div");
  logo.className = "empty-workspace-logo";
  logo.setAttribute("role", "img");
  logo.setAttribute("aria-label", "cmux Windows");
  logo.innerHTML = `
    <svg viewBox="0 0 180 180" aria-hidden="true" focusable="false">
      <rect class="empty-logo-shell" width="180" height="180" rx="28"></rect>
      <rect class="empty-logo-window" x="34" y="38" width="112" height="88" rx="10"></rect>
      <rect class="empty-logo-accent" x="46" y="54" width="54" height="8" rx="4"></rect>
      <rect class="empty-logo-line strong" x="46" y="74" width="86" height="8" rx="4"></rect>
      <rect class="empty-logo-line" x="46" y="94" width="66" height="8" rx="4"></rect>
      <path class="empty-logo-stand" d="M64 142h52"></path>
      <path class="empty-logo-stand" d="M90 126v18"></path>
      <circle class="empty-logo-dot" cx="129" cy="54" r="5"></circle>
      <path class="empty-logo-check" d="M57 119 72 134l34-42"></path>
    </svg>
  `;
  return logo;
}

function ensureEmptyWorkspaceLogo(node) {
  const inner = node?.querySelector(".empty-workspace-inner");
  if (!inner || inner.querySelector(".empty-workspace-logo")) return;
  inner.prepend(createEmptyWorkspaceLogo());
}

function createLauncherButton() {
  const button = document.createElement("button");
  button.className = "empty-workspace-launcher";
  button.type = "button";
  button.innerHTML = `
    <span class="empty-workspace-launcher-icon"></span>
    <span class="empty-workspace-launcher-text">
      <span class="empty-workspace-launcher-label"></span>
      <span class="empty-workspace-launcher-meta"></span>
    </span>
    <span class="empty-workspace-launcher-plus" aria-hidden="true"></span>
  `;
  button._emptyLauncherParts = launcherButtonParts(button);
  button.onclick = () => {
    if (button.disabled) return;
    button._emptyLauncherRun?.(button._emptyLauncherConfig);
  };
  return button;
}

function launcherButtonParts(button) {
  button._emptyLauncherParts ||= {
    icon: button.querySelector(".empty-workspace-launcher-icon"),
    label: button.querySelector(".empty-workspace-launcher-label"),
    meta: button.querySelector(".empty-workspace-launcher-meta"),
    plus: button.querySelector(".empty-workspace-launcher-plus")
  };
  return button._emptyLauncherParts;
}

function setIconMarkupIfChanged(node, key, markup) {
  if (!node || node.dataset.iconKey === key) return;
  node.dataset.iconKey = key;
  node.innerHTML = markup;
}

function updateLauncherButton(button, launcher, options) {
  const iconMarkup = options.iconMarkup || (() => "");
  const busy = Boolean(launcher.busy ?? options.busy);
  const meta = busy && launcher.busyMeta ? launcher.busyMeta : launcher.meta || "";
  const launcherLabel = meta ? `${launcher.label}: ${meta}` : launcher.label;
  const busyLabel = launcher.busyLabel || options.busyLabel || "Action unavailable";
  const parts = launcherButtonParts(button);
  button._emptyLauncherConfig = launcher;
  button._emptyLauncherRun = options.onRun;
  setDatasetIfChanged(button, "emptyLauncher", launcher.id);
  toggleClassIfChanged(button, "is-primary", launcher.primary);
  toggleClassIfChanged(button, "is-add", launcher.addAction);
  toggleClassIfChanged(button, "is-busy", busy);
  toggleClassIfChanged(button, "has-plus", launcher.addAction);
  setDisabledIfChanged(button, busy);
  setTitleIfChanged(button, busy ? busyLabel : launcherLabel);
  setAttributeIfChanged(button, "aria-label", busy ? `${launcherLabel}. ${busyLabel}.` : launcherLabel);
  setIconMarkupIfChanged(parts.icon, launcher.icon, iconMarkup(launcher.icon));
  setTextIfChanged(parts.label, launcher.label);
  setTextIfChanged(parts.meta, meta);
  toggleClassIfChanged(parts.plus, "is-visible", launcher.addAction);
  setIconMarkupIfChanged(parts.plus, launcher.addAction ? "plus" : "", launcher.addAction ? iconMarkup("plus") : "");
}

function renderEmptyWorkspaceLaunchers(node, options) {
  const host = node.querySelector(".empty-workspace-launchers");
  if (!host) return;
  const existing = new Map(
    [...host.children]
      .filter((child) => child.dataset.emptyLauncher)
      .map((child) => [child.dataset.emptyLauncher, child])
  );
  const cards = (options.launchers || []).map((launcher) => {
    const existingButton = existing.get(launcher.id);
    const button = existingButton?.querySelector(".empty-workspace-launcher-plus")
      ? existingButton
      : createLauncherButton();
    updateLauncherButton(button, launcher, options);
    return button;
  });
  replaceChildrenIfChanged(host, cards);
}

export function createEmptyWorkspaceView(options = {}) {
  const node = document.createElement("div");
  node.className = "empty-workspace";
  node.innerHTML = `
    <div class="empty-workspace-inner">
      <div class="empty-workspace-title"></div>
      <div class="empty-workspace-body"></div>
      <div class="empty-workspace-launchers"></div>
    </div>
  `;
  updateEmptyWorkspaceView(node, options);
  return node;
}

export function updateEmptyWorkspaceView(node, options = {}) {
  if (!node) return;
  ensureEmptyWorkspaceLogo(node);
  setTextIfChanged(node.querySelector(".empty-workspace-title"), options.title || "cmux");
  setTextIfChanged(node.querySelector(".empty-workspace-body"), options.bodyText || "Start with a shell or browser.");
  renderEmptyWorkspaceLaunchers(node, options);
}
