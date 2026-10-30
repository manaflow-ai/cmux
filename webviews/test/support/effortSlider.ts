/// The model menu's effort slider (QuickModelMenu `effortSlider`, EffortTrack `compact`) in DOM tests:
/// one native range per model row that offers levels, named "<model> · Effort", with a stop per level
/// (`data-level` its id, `data-name` its name) and the level it rests on named once beside it.

export function effortRange(doc: Document | Element, model: string): HTMLInputElement | null {
  return doc.querySelector<HTMLInputElement>(
    `.acpmux-quick-effort input[type="range"][aria-label="${model} · Effort"]`,
  );
}

/// Every effort stop the menu draws, across its rows (one per level a row offers).
export function effortStops(doc: Document | Element): HTMLElement[] {
  return [...doc.querySelectorAll<HTMLElement>(".acpmux-quick-effort .acpmux-effort-stop")];
}

/// A model row's stop for the level named `level`, or null when the row offers no such level.
export function effortStop(doc: Document | Element, model: string, level: string): HTMLElement | null {
  return (
    effortRange(doc, model)
      ?.closest(".acpmux-effort-track")
      ?.querySelector<HTMLElement>(`.acpmux-effort-stop[data-name="${level}"]`) ?? null
  );
}

/// The level names a model row's slider offers, in order.
export function effortLevels(doc: Document | Element, model: string): string[] {
  const track = effortRange(doc, model)?.closest(".acpmux-effort-track");
  return [...(track?.querySelectorAll<HTMLElement>(".acpmux-effort-stop") ?? [])].map(
    (stop) => stop.dataset.name ?? "",
  );
}

/// The level a slider rests on, as named beside it.
export function restingEffort(range: HTMLInputElement | null): string | undefined {
  return range?.closest(".acpmux-quick-effort")?.querySelector(".acpmux-quick-effort-level")?.textContent ?? undefined;
}

/// Sets a range to `index` and releases it, as a click at that stop does.
function release(range: HTMLInputElement, index: number): void {
  const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(range), "value")?.set;
  setter?.call(range, String(index));
  const View = range.ownerDocument.defaultView!;
  range.dispatchEvent(new View.Event("input", { bubbles: true }));
  range.dispatchEvent(new View.Event("change", { bubbles: true }));
  range.click();
}

/// One level of a row's slider: its name, whether the thumb rests on it, and a click on its stop
/// (which lands the row's model with it). Wrap click() in act().
export type EffortSegment = { name: string; checked: boolean; click(): void };

/// The levels of the slider inside `scope` (a model row's `.acpmux-quick-model-effort`, or the list
/// look's Effort row).
export function effortSegments(scope: Element | null | undefined): EffortSegment[] {
  const range = scope?.querySelector<HTMLInputElement>('.acpmux-quick-effort input[type="range"]');
  const track = range?.closest(".acpmux-effort-track");
  if (!range || !track) return [];
  return [...track.querySelectorAll<HTMLElement>(".acpmux-effort-stop")].map((stop, index) => ({
    name: stop.dataset.name ?? "",
    checked: stop.hasAttribute("data-at"),
    click: () => release(range, index),
  }));
}

/// Moves a model row's slider to the level named `level` and releases it, as a click on that stop
/// does: the row lands the model with that level. Wrap it in act().
export function pickEffortLevel(doc: Document | Element, model: string, level: string): void {
  const range = effortRange(doc, model);
  if (!range) throw new Error(`no effort slider for ${model}`);
  const names = effortLevels(doc, model);
  const index = names.indexOf(level);
  if (index < 0) throw new Error(`${model} offers no ${level} (${names.join(", ")})`);
  release(range, index);
}
