// The composer's model picker's props, the combos it lands, and its height bounds (ModelPicker.tsx).
import type { AcpmuxSnapshot } from "./model";
import type { Choice, Combo } from "./ComposerPickers";
import type { QuickMenuExtras } from "./QuickModelMenu";
import type { PickerProfile } from "./pickerProfiles";
import type { SpeedTiers } from "./FastToggle";

/// What the picker gets from ComposerPickers. Picks go through `onLand` (model, then its effort
/// once the agent reports that model) and `onEffort`.
export type ModelPickerProps = {
  /// `top`: the harness's own model-menu order, when reported; other models fold under More models.
  catalog: (AcpmuxSnapshot["catalog"][number] & { top?: readonly string[] })[];
  harness?: string;
  model?: string;
  /// The chip's text: the current model's name, or its id when the catalog doesn't list it.
  label: string;
  /// What the composer's controls row draws in the chip (composerRowFit.ts): the name without its
  /// vendor ("Opus 5.5") and its family ("Opus") for a narrow row; `title` names the model in the
  /// tooltip of the row's mark-only chip. Away from the row the chip shows `label`.
  chip?: { short?: string; family?: string; title?: string };
  /// A harness switch in flight: the chip draws this harness's mark and name until it starts.
  switching?: { harness: string; name: string; mark?: string };
  /// The chip's secondary text after the model: the chosen effort, when it is not the default.
  detail?: string;
  /// How much of the context window the chat has used ("42% of context used"), shown in the
  /// chip's tooltip: the controls row draws no context ring (hq#1957 item 15 compact row).
  usage?: string;
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
  speed?: SpeedTiers;
  /** Refreshes the host-backed model catalog; the host owns transport and live events. */
  catalogRefresh?: CatalogRefreshState;
  /// Starts a new chat in another harness; without it, other harnesses are not offered.
  onHarness?(harness: string): void;
  /// One pick of a model with the effort and fast mode a typed query named ("gpt medium fast"),
  /// in this harness or another (which starts a new chat there, then applies the rest).
  onCombo?(combo: ModelCombo): void;
  /// The pointer or keyboard rests on a harness row (undefined: the menu closed), for acpmux's
  /// prewarm hint (harnessSwitch.ts).
  onHarnessHint?(harness: string | undefined): void;
  /// Enables the chat folder's profile `id` from `folder` (a "needs Enable" row's pick). Called
  /// from the click or key handler itself: the host's confirmation needs the gesture.
  onHarnessEnable?(folder: string, id: string): void;
  /// Add harness…, the menu's last row: the pane's Harnesses page, in place (cx-uj5g8).
  onAddAgent?(): void;
  /// Set while the picker is mounted to a call that opens its menu (the compact one when `quick`
  /// is set), whose rail switches harness: the footer's harness item opens it (ComposerHarness.tsx).
  opener?: { current: (() => void) | undefined };
  /// The chat has started, so its harness is fixed, as in Claude Code (Leo 2026-10-19): the menu
  /// lists `harness`'s models alone, with search and More models, and no harness rail, Starred tab
  /// or Add harness…; the compact menu draws no rail either. A New Tab or a chat with no message
  /// yet leaves it unset and keeps the whole rail.
  harnessFixed?: boolean;
  /// With `harnessFixed`, the started chat can fork to another harness (Leo 2026-10-22: "need to be
  /// able to switch to different harnesses, can expose as fork"): the compact menu keeps the whole
  /// rail, and another harness's tab, or another account of the chat's own, offers Fork to it.
  /// `to` gets the acpmux profile id; `ready` false (a turn running, a queued prompt) disables it.
  fork?: { to(harness: string): void; ready: boolean };
  /// The installed acpmux profiles each catalog entry stands for, by its id (pickerProfiles.ts): the
  /// launch configurations shown as named harness entries. An entry with none listed is its own profile.
  profiles?: Readonly<Record<string, readonly PickerProfile[]>>;
  /// A short note per harness in place of "New chat" (a harness that failed to start).
  harnessNotes?: Readonly<Record<string, string>>;
  /// The harnesses this Mac's acpmux found signed out, by acpmux id, with each one's login
  /// command (cx-ae9eb). Their rail tab dims and lists Log In in place of models; none of their
  /// models can be picked, so a pick never starts a chat that fails on its first turn.
  signedOut?: Readonly<Record<string, string>>;
  /// Runs a signed-out harness's login (its Log In row).
  onLogIn?(harness: string, login: string): void;
  /// The compact menu a click on the chip opens (QuickModelMenu). Every composer passes it (Leo
  /// 2026-10-20: one model button); the full picker is its More models row. Without it (a picker
  /// on its own) the chip opens the full picker at once. With it the chip draws `detail` (the
  /// effort) after the model and no chevron.
  quick?: QuickMenuExtras;
  /// The effort's short name ("Med") the compact chip shows in a narrow row (composerRowFit.ts).
  detailShort?: string;
  /// The room, in px, left of the open menu for its submenus (`menuRoom`). Tests pass a
  /// number in place of real layout.
  measureRoom?(menu: HTMLElement): number;
};

export type ModelCombo = { harness: string; model: string; effort?: string; fast?: boolean };

export type CatalogRefreshState = {
  status?: "idle" | "fetching" | "updated" | "error";
  /** ISO timestamp for the catalog copy shown by the picker. */
  date?: string;
  refresh(): void | Promise<void>;
};

/// A fallback while the anchor has not measured its available room yet. Once measured, the
/// picker uses all the available height, with no fixed cap.
const MODEL_PICKER_INITIAL_HEIGHT = 480;
/// The shortest the open picker gets: the search field and about six model rows. A chip with less
/// room than this, or a list that loads after the menu opened, never collapses the menu to its
/// search field (Lawrence 2026-10-13). The menu opens on the side of the chip that has this much
/// room (`useUiAnchor` `minHeight`; Leo: the menu stays inside the page). Only when neither side
/// has it does it open below and run past the room, where the page scrolls to it; above, it ran off
/// the top of the window (the New Tab chip's menu, 94 px).
export const MODEL_PICKER_MIN_HEIGHT = 220;

/// The agent pane's chat column: the model menus and their submenus stay inside it, never over the
/// session rail, summary column or sidebar beside it (a composer outside one keeps to the window).
export const CHAT_COLUMN = ".acpmux-main";

/// The open picker's height bounds: at most the anchor's room (`room`, when known); at least
/// MODEL_PICKER_MIN_HEIGHT when that fits, or its height when it
/// opened (`opened`), so a narrowing search does not shrink it, while a list that loads later can
/// still grow it.
export function pickerHeightBounds(
  room: unknown,
  opened: number | undefined,
): { maxHeight: number; minHeight: number } {
  const maxHeight = typeof room === "number" && Number.isFinite(room) ? Math.max(0, room) : MODEL_PICKER_INITIAL_HEIGHT;
  const minHeight = Math.min(maxHeight, Math.max(MODEL_PICKER_MIN_HEIGHT, opened ?? 0));
  return { maxHeight, minHeight };
}
