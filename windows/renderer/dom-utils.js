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

export function setDatasetIfChanged(node, key, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.dataset[key] === next) return false;
  node.dataset[key] = next;
  return true;
}

export function setStylePropertyIfChanged(node, name, value) {
  if (!node) return false;
  const next = String(value ?? "");
  if (node.style.getPropertyValue(name) === next) return false;
  node.style.setProperty(name, next);
  return true;
}
