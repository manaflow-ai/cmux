export type PickerRailElement = {
  style: { setProperty(name: string, value: string, priority?: string): void; removeProperty(name: string): void };
};
export type PickerRailBox = { clientWidth: number; scrollWidth: number };

/** Keep a narrow picker rail's scroll endpoints on complete 32px marks plus 4px gaps. */
export function quantizePickerRail(
  rail: PickerRailElement,
  container: PickerRailBox,
  viewport: PickerRailBox,
  narrow: boolean,
): void {
  if (!narrow) {
    rail.style.removeProperty("width");
    return;
  }
  const available = container.clientWidth;
  if (viewport.scrollWidth <= available) {
    rail.style.removeProperty("width");
    return;
  }
  const cells = Math.max(1, Math.floor((available - 12 + 4) / 36));
  rail.style.setProperty("width", `${cells * 36 - 4 + 12}px`, "important");
}
