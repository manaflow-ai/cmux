import React from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { SettingsShell } from "./settings/SettingsShell.jsx";

const roots = new WeakMap();

export function renderSettingsShell(container, props) {
  let root = roots.get(container);
  if (!root) {
    root = createRoot(container);
    roots.set(container, root);
  }
  flushSync(() => {
    root.render(<SettingsShell {...props} />);
  });
}

export function unmountSettingsShell(container) {
  const root = roots.get(container);
  if (!root) return;
  root.unmount();
  roots.delete(container);
}
