// What the composer's model picker shares between its two layouts: the cascade (submenus beside
// their rows) and, when the pane has no room beside the menu, the in-place drill.
import type React from "react";
import { useLayoutEffect } from "react";
import type { AcpmuxSnapshot } from "./model";
import type { Choice, Combo } from "./ComposerPickers";

/// What the picker gets from ComposerPickers. Picks go through `onLand` (model, then its effort
/// once the agent reports that model) and `onEffort`.
export type ModelPickerProps = {
  catalog: AcpmuxSnapshot["catalog"];
  harness?: string;
  model?: string;
  /// The chip's text: the current model's name, or its id when the catalog doesn't list it.
  label: string;
  /// The chip's secondary text after the model: the chosen effort, when it is not the default.
  detail?: string;
  /// The name of the model the agent's default resolves to, when known: the "Default" row draws
  /// as that model with a "Default" hint.
  resolvedDefault?: string;
  efforts: Choice[];
  effort?: string;
  /// The viewer's recent combos, newest first (any harness; the picker keeps this harness's).
  recents: Combo[];
  onLand(model: string, effort?: string): void;
  onEffort(value: string): void;
  fastMode?: {
    name: string;
    currentValue?: string;
    onValue: string;
    offValue: string;
    onLabel: string;
    offLabel: string;
    onPick(value: string): void;
  };
  /** Refreshes the host-backed model catalog; the host owns transport and live events. */
  catalogRefresh?: CatalogRefreshState;
  /// Starts a new chat in another harness; without it, other harnesses are not offered.
  onHarness?(harness: string): void;
  /// The pointer or keyboard rests on a harness row (undefined: the menu closed), for acpmux's
  /// prewarm hint (harnessSwitch.ts).
  onHarnessHint?(harness: string | undefined): void;
  /// Enables the chat folder's profile `id` from `folder` (a "needs Enable" row's pick). Called
  /// from the click or key handler itself: the host's confirmation needs the gesture.
  onHarnessEnable?(folder: string, id: string): void;
  /// A short note per harness in place of "New chat" (a harness that failed to start).
  harnessNotes?: Readonly<Record<string, string>>;
  /// The room, in px, left of the open menu for its submenus (`menuRoom`). Tests pass a
  /// number in place of real layout.
  measureRoom?(menu: HTMLElement): number;
};

export type CatalogRefreshState = {
  status?: "idle" | "fetching" | "updated" | "error";
  /** ISO timestamp for the catalog copy shown by the picker. */
  date?: string;
  refresh(): void | Promise<void>;
};

/// The keys and pointer moves the chip forwards to the open menu's body.
export type MenuHandle = {
  keyDown(event: React.KeyboardEvent): void;
  track(event: React.PointerEvent): void;
};

/// What ModelPicker hands the layout it chose. The body mounts with the menu and unmounts when it
/// closes, so a query, an open path or an expanded fold never outlives one opening.
export type ModelMenuProps = ModelPickerProps & {
  trigger: React.RefObject<HTMLButtonElement | null>;
  menu: React.RefObject<HTMLDivElement | null>;
  handle: React.RefObject<MenuHandle | undefined>;
  close(): void;
};

/// How many recents the menu numbers (keys 1 to this).
export const RECENT_ROWS = 4;
/// Rows a level shows before "More…".
export const LEVEL_ROWS = 3;
/// How long the pointer rests on a row before its submenu opens.
export const HOVER_INTENT_MS = 150;
/// The width one side submenu takes beside the menu: the widest (the reasoning slider, 240px)
/// plus the 10px gap. Family and model submenus are at least 210px.
export const SUBMENU_ROOM = 250;

export type PickerLayout = "cascade" | "drill";

/// The cascade when every side submenu fits between the pane's left edge and the menu, else the
/// in-place drill. `depth` is how many submenus can stand side by side: 2 when the harness's
/// models sit under providers and then families, else 1.
export function pickerLayout(room: number, depth: number): PickerLayout {
  return room >= depth * SUBMENU_ROOM ? "cascade" : "drill";
}

/// The room left of the open menu: its left edge in the page, which is the pane.
export const menuRoom = (menu: HTMLElement) => menu.getBoundingClientRect().left;

/// Hands the chip a body's keys and pointer tracking, and names its highlighted row on the chip
/// for screen readers following the keys. Both go away when the body unmounts.
export function useMenuHandle({ trigger, handle }: ModelMenuProps, keys: MenuHandle, activeId?: string) {
  useLayoutEffect(() => {
    handle.current = keys;
    return () => {
      handle.current = undefined;
    };
  });
  useLayoutEffect(() => {
    const chip = trigger.current;
    if (!chip) return;
    if (activeId) chip.setAttribute("aria-activedescendant", activeId);
    else chip.removeAttribute("aria-activedescendant");
    return () => chip.removeAttribute("aria-activedescendant");
  }, [trigger, activeId]);
}
