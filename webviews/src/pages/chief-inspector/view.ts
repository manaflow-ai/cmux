// What the remote Chief memory inspector keeps across a discard: its tab, the turn
// the Prompt tab shows and the Tree's zoom path. The inspector reads everything else again.
import { TAB_IDS, type InspectorView } from "../../optchat-inspector/App";

/** The page name its saved state carries (pageState.ts). */
export const CHIEF_INSPECTOR_PAGE = "chief-inspector";

/** The most zoom steps a saved path keeps; a deeper one is not a path a person walked. */
const MAX_PATH = 64;

/** The valid fields of the view a discarded document saved; the rest keep their defaults. */
export function restoredInspectorView(state: unknown): Partial<InspectorView> {
  if (!state || typeof state !== "object") return {};
  const saved = state as Record<string, unknown>;
  const view: Partial<InspectorView> = {};
  const tab = TAB_IDS.find((known) => known === saved.tab);
  if (tab) view.tab = tab;
  if (typeof saved.turn === "string" && saved.turn) view.turn = saved.turn;
  if (
    Array.isArray(saved.path) &&
    saved.path.length <= MAX_PATH &&
    saved.path.every((step): step is string => typeof step === "string")
  )
    view.path = saved.path;
  return view;
}
