/**
 * Where an Opacity slider over a picture starts: the legibility floor the app reports
 * (`derived_min`), rounded up onto the slider's step grid and never past its cap. The window never
 * paints a tint below that floor, so the travel under it moved nothing (Leo, 10-19: "the slider
 * still doesn't work"). Returns `origin` without a floor; a result equal to `max` leaves no travel.
 */
export function opacityFloorOnGrid(floor: number | undefined, origin: number, step: number, max: number): number {
  if (floor === undefined || !(floor > origin)) return origin;
  if (!(step > 0)) return Math.min(max, floor);
  const steps = Math.ceil((floor - origin) / step - 1e-9);
  return Math.min(max, Math.round((origin + steps * step) * 100) / 100);
}
