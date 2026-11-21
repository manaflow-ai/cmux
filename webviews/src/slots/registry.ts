// Theme slots: a named place in the UI whose look and motion a theme can swap (schemas/theme/slots.json,
// docs/cmux-next/extensions/replace-a-slot.md). Leo, 2026-11-10: "it's just like little bits and pieces
// like that, the little bits of like delight and joy that users can have."
//
// A slot is defined once (`defineSlot`, its spec read from slots.json: props, motion tokens, reduced
// motion, box, stop condition) and drawn with `<Slot>` (Slot.tsx). Variants register against it
// (`registerSlotVariant`); cmux's own default ships the same way a theme pack's variant would. One
// host draws its default in place: the live line (Thinking.tsx `LiveWords`) draws the built-in
// thinking indicator's markup itself, so its shimmer band stays one element through a named step.
//
// The variant a slot draws comes from one place, in this order, as experiments pick an arm
// (experiments/experiment.ts) but for a lasting theme choice rather than a comparison:
//   1. an override the host installs before the page loads (`globalThis.cmuxSlots`: the gallery or a
//      dev harness);
//   2. the debug key `cmux.slots` in localStorage, a JSON object `{ "<slot id>": "<variant id>" }`;
//   3. the theme look's `slots` map: the agent pane's theme push (`applyAgentTheme`) or the shared web
//      theme (`window.cmuxTheme.current.slots`);
//   4. the slot's default variant.
// A source naming a variant no one registered falls through to the next, so a stale theme or key never
// blanks a slot. A variant that throws while rendering is caught per slot (Slot.tsx) and the default
// draws in its place.
import { useSyncExternalStore, type ComponentType } from "react";
import slotsSchema from "../../../schemas/theme/slots.json";

export const SLOT_ID = /^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$/;
export const VARIANT_ID = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export const SLOTS_STORAGE_KEY = "cmux.slots";

/** One slot's entry in schemas/theme/slots.json. */
export type SlotSpec = (typeof slotsSchema.slots)[number];

export type SlotDefinition<Props> = {
  id: string;
  title: string;
  defaultVariant: string;
  spec: SlotSpec;
  /** Type only: the props every variant takes. */
  readonly props?: Props;
};

export type SlotVariant<Props> = { id: string; component: ComponentType<Props> };

export type SlotMap = Record<string, string>;

declare global {
  // eslint-disable-next-line no-var -- a host-installed global, read once per lookup.
  var cmuxSlots: SlotMap | undefined;
}

/** A slot by its schema entry: its id must be in slots.json, and its default comes from there. */
export function defineSlot<Props>(
  id: string,
  schema: { slots: readonly SlotSpec[] } = slotsSchema,
): SlotDefinition<Props> {
  const spec = schema.slots.find((slot) => slot.id === id);
  if (!spec) throw new Error(`theme slot ${id}: no entry in schemas/theme/slots.json`);
  if (!SLOT_ID.test(id)) throw new Error(`theme slot ${id}: ids are dotted lower camel case (chat.thinkingIndicator)`);
  return { id, title: spec.title, defaultVariant: spec.defaultVariant, spec };
}

const variants = new Map<string, Map<string, ComponentType<never>>>();
const failures = new Map<string, { variant: string; error: unknown }>();
let themeSlots: SlotMap | undefined;
let version = 0;
const listeners = new Set<() => void>();

function changed(): void {
  version += 1;
  for (const listener of listeners) listener();
}

/** Adds (or replaces) `variantId` of `slot`. A theme pack registers its own the same way cmux does. */
export function registerSlotVariant<Props>(
  slot: SlotDefinition<Props>,
  variantId: string,
  component: ComponentType<Props>,
): void {
  if (!VARIANT_ID.test(variantId))
    throw new Error(`theme slot ${slot.id}: variant ids are lower kebab case (${variantId})`);
  let byId = variants.get(slot.id);
  if (!byId) variants.set(slot.id, (byId = new Map()));
  byId.set(variantId, component as ComponentType<never>);
  failures.delete(slot.id);
  changed();
}

/** The variant ids registered for `slotId`, in registration order. */
export function slotVariantIds(slotId: string): string[] {
  return [...(variants.get(slotId)?.keys() ?? [])];
}

function slotMap(value: unknown): SlotMap | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const map: SlotMap = {};
  for (const [slot, variant] of Object.entries(value)) if (typeof variant === "string") map[slot] = variant;
  return map;
}

/** The theme look carried a `slots` map (or none): every slot follows at once. Absent clears it. */
export function configureThemeSlots(value: unknown): void {
  const next = slotMap(value);
  if (JSON.stringify(next) === JSON.stringify(themeSlots)) return;
  themeSlots = next;
  changed();
}

let stored: SlotMap | undefined;

/** The debug key, read once per page (set it in the web inspector and reload, as `cmux.experiments`). */
function storedSlots(): SlotMap {
  return (stored ??= readStoredSlots());
}

function readStoredSlots(): SlotMap {
  try {
    const text = globalThis.localStorage?.getItem(SLOTS_STORAGE_KEY);
    return slotMap(text ? JSON.parse(text) : undefined) ?? {};
  } catch {
    // No storage (a sandboxed page) or a malformed value: no override.
    return {};
  }
}

function hostThemeSlots(): SlotMap | undefined {
  const host = (globalThis as { cmuxTheme?: { current?: { slots?: unknown } | null } }).cmuxTheme;
  return slotMap(host?.current?.slots);
}

export type SlotSources = { overrides?: SlotMap; stored?: SlotMap; theme?: SlotMap };

/** The variant id `slot` draws: the first source naming a registered variant, else the default. */
export function selectedSlotVariant(slot: SlotDefinition<unknown>, sources: SlotSources = {}): string {
  const registered = variants.get(slot.id);
  const candidates = [
    (sources.overrides ?? globalThis.cmuxSlots)?.[slot.id],
    (sources.stored ?? storedSlots())[slot.id],
    (sources.theme ?? themeSlots ?? hostThemeSlots())?.[slot.id],
  ];
  for (const id of candidates) if (id !== undefined && registered?.has(id)) return id;
  return slot.defaultVariant;
}

/** The component for `variantId`, else the default's; undefined only when the default is not registered. */
export function slotVariant<Props>(slot: SlotDefinition<Props>, variantId: string): SlotVariant<Props> | undefined {
  const byId = variants.get(slot.id);
  const component = byId?.get(variantId) ?? byId?.get(slot.defaultVariant);
  if (!component) return undefined;
  return { id: byId?.has(variantId) ? variantId : slot.defaultVariant, component: component as ComponentType<Props> };
}

/** A variant threw: the slot drew its default instead (Slot.tsx). Kept for the gallery and tests. */
export function reportSlotFailure(slotId: string, variant: string, error: unknown): void {
  failures.set(slotId, { variant, error });
  console.warn(`theme slot ${slotId}: variant ${variant} failed; drawing the default`, error);
}

/** The last variant of `slotId` that threw, if any since it was registered again. */
export function slotFailure(slotId: string): { variant: string; error: unknown } | undefined {
  return failures.get(slotId);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  // The shared web theme's pushes (WebTheme.swift `cmuxTheme.apply`) dispatch `cmux-theme`.
  const win = globalThis.window;
  win?.addEventListener?.("cmux-theme", listener);
  return () => {
    listeners.delete(listener);
    win?.removeEventListener?.("cmux-theme", listener);
  };
}

/** The variant id `slot` draws now, following theme pushes and registrations. Changes only when one
 * of those does, so a slot adds no commit of its own. */
export function useSlotVariant(slot: SlotDefinition<unknown>): string {
  const read = () => selectedSlotVariant(slot);
  return useSyncExternalStore(subscribe, read, read);
}

/** For tests: forget registrations, failures and the theme map. */
export function resetSlotsForTest(): void {
  variants.clear();
  failures.clear();
  themeSlots = undefined;
  stored = undefined;
  changed();
}

/** Bumps on every change; for tests that count notifications. */
export const slotsVersion = (): number => version;
