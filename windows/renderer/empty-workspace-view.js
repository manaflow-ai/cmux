import {
  replaceChildrenIfChanged,
  setTextIfChanged,
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
  return button;
}

function updateLauncherButton(button, launcher, options) {
  const iconMarkup = options.iconMarkup || (() => "");
  const busy = Boolean(options.busy);
  const launcherLabel = `${launcher.label}: ${launcher.meta}`;
  const busyLabel = options.busyLabel || "Action unavailable";
  button.dataset.emptyLauncher = launcher.id;
  toggleClassIfChanged(button, "is-primary", launcher.primary);
  toggleClassIfChanged(button, "is-add", launcher.addAction);
  toggleClassIfChanged(button, "has-plus", launcher.addAction);
  button.disabled = busy;
  button.title = busy ? busyLabel : launcherLabel;
  button.setAttribute("aria-label", busy ? `${launcherLabel}. ${busyLabel}.` : launcherLabel);
  button.querySelector(".empty-workspace-launcher-icon").innerHTML = iconMarkup(launcher.icon);
  setTextIfChanged(button.querySelector(".empty-workspace-launcher-label"), launcher.label);
  setTextIfChanged(button.querySelector(".empty-workspace-launcher-meta"), launcher.meta);
  const plus = button.querySelector(".empty-workspace-launcher-plus");
  toggleClassIfChanged(plus, "is-visible", launcher.addAction);
  plus.innerHTML = launcher.addAction ? iconMarkup("plus") : "";
  button.onclick = () => options.onRun?.(launcher);
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
