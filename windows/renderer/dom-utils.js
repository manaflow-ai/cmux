export function replaceChildrenIfChanged(parent, nodes) {
  if (parent.childNodes.length === nodes.length && nodes.every((node, index) => parent.childNodes[index] === node)) {
    return false;
  }
  parent.replaceChildren(...nodes);
  return true;
}

export function setTextIfChanged(node, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.textContent === next) return false;
  node.textContent = next;
  return true;
}

export function setTitleIfChanged(node, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.title === next) return false;
  node.title = next;
  return true;
}

export function setClassNameIfChanged(node, value) {
  if (!node || node.className === value) return false;
  node.className = value;
  return true;
}

export function toggleClassIfChanged(node, className, enabled) {
  if (!node) return false;
  const shouldEnable = Boolean(enabled);
  if (node.classList.contains(className) === shouldEnable) return false;
  node.classList.toggle(className, shouldEnable);
  return true;
}

export function setHiddenIfChanged(node, hidden) {
  if (!node) return false;
  const next = Boolean(hidden);
  if (node.hidden === next) return false;
  node.hidden = next;
  return true;
}

export function setDisabledIfChanged(node, disabled) {
  if (!node) return false;
  const next = Boolean(disabled);
  if (node.disabled === next) return false;
  node.disabled = next;
  return true;
}

export function setDatasetIfChanged(node, key, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.dataset[key] === next) return false;
  node.dataset[key] = next;
  return true;
}

export function setAttributeIfChanged(node, name, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.getAttribute(name) === next) return false;
  node.setAttribute(name, next);
  return true;
}

export function setStylePropertyIfChanged(node, name, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.style.getPropertyValue(name) === next) return false;
  node.style.setProperty(name, next);
  return true;
}
