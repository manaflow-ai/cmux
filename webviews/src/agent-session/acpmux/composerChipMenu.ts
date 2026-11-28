import type { MouseEvent } from "react";
import { openPicker } from "./pickerOpeners";

/// A right-click on one of the composer's menu buttons (the + menu, model, effort, access, the
/// folder and computer chips) opens that button's own menu, as a click does (cx-2lm4): wherever a
/// control opens a menu, right-click shows the same menu. It runs in the capture phase, before the
/// footer's Show Context Usage menu around the chips; a button with a right-click menu of its own
/// (the context ring: the only menu button in its `ContextMenu`) keeps that menu.
export function openChipMenu(event: MouseEvent<HTMLElement>) {
  if (!(event.target instanceof Element)) return;
  const trigger = event.target.closest<HTMLButtonElement>("button[aria-haspopup]");
  if (!trigger || !event.currentTarget.contains(trigger)) return;
  const host = trigger.closest(".ui-context-menu-host");
  if (host && host.querySelectorAll("button[aria-haspopup]").length === 1) return;
  event.preventDefault();
  event.stopPropagation();
  if (trigger.disabled || trigger.getAttribute("aria-expanded") === "true") return;
  // A menu that opens on a press, not a click (the access and effort menus), opens through its
  // registered opener (pickerOpeners.ts), by the name automation finds it by.
  const name = trigger.dataset.menu ?? trigger.getAttribute("aria-label");
  if (!name || !openPicker(name)) trigger.click();
}
