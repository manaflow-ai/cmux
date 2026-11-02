// A model's effort is a side dropdown beside its row in the compact model menu (#27948): its effort
// item opens a submenu of the model's levels. These open it in a jsdom test and return its levels.
import { act } from "react";

/// Opens the effort dropdown of the model named `model` (else the running model's, else the first)
/// and returns its level items; none when no row has an effort item.
export async function openEffort(doc: Document, model?: string): Promise<HTMLElement[]> {
  const triggers = [...doc.querySelectorAll<HTMLElement>(".acpmux-quick-effort-trigger")];
  const trigger = model
    ? triggers.find((item) => {
        // Its accessible name ends "<model> · Effort"; match the whole model name, so "Fable 5.1"
        // never opens "Fable 5.1 · 1M context".
        const name = item.querySelector(".sr-only")?.textContent ?? "";
        return name.slice(0, name.lastIndexOf(" · ")) === model;
      })
    : (triggers.find((item) => item.closest("[data-running]")) ?? triggers[0]);
  if (!trigger) return [];
  if (!trigger.hasAttribute("data-popup-open")) {
    await act(async () => trigger.click());
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  }
  return [...doc.querySelectorAll<HTMLElement>(".acpmux-quick-effort-menu .acpmux-quick-effort-segment")];
}

/// The level item labelled `label` ("Model · Level"), with its model's dropdown opened first.
export async function effortLevel(doc: Document, label: string): Promise<HTMLElement | null> {
  await openEffort(doc, label.slice(0, label.lastIndexOf(" · ")));
  return doc.querySelector<HTMLElement>(`.acpmux-quick-effort-segment[aria-label="${label}"]`);
}
