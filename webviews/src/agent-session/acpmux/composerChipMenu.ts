import type { MouseEvent } from "react";
import { openPicker } from "./pickerOpeners";

/// Marks a chip whose right-click opens its own menu, not the menu a click opens (openChipMenu).
export const OWN_CONTEXT_MENU = "data-own-context-menu";

/// A right-click on one of the composer's menu buttons (the + menu, model, effort, access, the
/// folder and computer chips) opens that button's own menu, as a click does (cx-2lm4): wherever a
/// control opens a menu, right-click shows the same menu. It runs in the capture phase, before the
/// footer's Show Context Usage menu around the chips; a button with a right-click menu of its own
/// (the context ring: the only menu button in its `ContextMenu`; a chip marked
/// `data-own-context-menu`, the model chip's Show Provider Logo and Show Effort) keeps that menu.
export function openChipMenu(event: MouseEvent<HTMLElement>) {
  if (!(event.target instanceof Element)) return;
  const trigger = event.target.closest<HTMLButtonElement>("button[aria-haspopup]");
  if (!trigger || !event.currentTarget.contains(trigger)) return;
  const host = trigger.closest(".ui-context-menu-host");
  if (host && host.querySelectorAll("button[aria-haspopup]").length === 1) return;
  // Only the marked chip's own button: a menu button in its open popup still opens its menu.
  const own = trigger.closest(`[${OWN_CONTEXT_MENU}]`);
  if (own && own.querySelector("button[aria-haspopup]") === trigger) return;
  event.preventDefault();
  event.stopPropagation();
  if (trigger.disabled || trigger.getAttribute("aria-expanded") === "true") return;
  // A menu that opens on a press, not a click (the access and effort menus), opens through its
  // registered opener (pickerOpeners.ts), by the name automation finds it by.
  const name = trigger.dataset.menu ?? trigger.getAttribute("aria-label");
  if (!name || !openPicker(name)) trigger.click();
}
