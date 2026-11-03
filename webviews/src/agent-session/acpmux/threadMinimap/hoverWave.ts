// The compact rail's hover wave: the ticks around the pointer grow as a smooth bump of their
// distance from the pointer's own y (model.ts `waveProgress`), not by whole rows. One loop eases the
// bump toward the pointer (`waveFollow`) and grows it in on the rail's spring when the pointer arrives
// (`waveAmplitude`); each frame it writes one custom property on the few ticks inside the bump's
// reach, which threadMinimap.css turns into the bar's and the dot's transforms. Nothing here reads or
// changes layout per frame, and React renders nothing for it.
//
// Loop: one requestAnimationFrame at a time, asked for by a pointer move or the list's scroll. It
// stops once the bump has reached the pointer (within 0.01 row) and the grow-in has ended, and the
// next move asks for it again. `leave()` (the pointer leaving the ticks, Reduce Motion, unmount)
// cancels a pending frame and clears every property it wrote.
import { ROW_PITCH, waveAmplitude, waveFollow, WAVE_IN_MS, waveProgress, type WaveShape } from "./model";

/// The custom property each tick in the bump's reach carries: its magnification, 0 to 1.
export const WAVE_PROPERTY = "--acpmux-minimap-wave";
/// The rail's attribute while the wave draws its ticks (threadMinimap.css): `moving` while its loop
/// runs, `still` once it has stopped (the gallery and the tests wait on it).
export const WAVE_ATTRIBUTE = "data-wave";

export class HoverWave {
  private frame: number | undefined;
  /// The bump's fractional row now, and the pointer's it eases toward.
  private focus = 0;
  private target = 0;
  private active = false;
  private startedAt = 0;
  private lastAt = 0;
  /// The ticks carrying the property, with the value each was last given.
  private readonly written = new Map<HTMLElement, number>();

  constructor(
    private readonly shape: WaveShape,
    private readonly rail: () => HTMLElement | null,
    private readonly list: () => HTMLElement | null,
    private readonly rows: () => number,
  ) {}

  /// The pointer is over the ticks at `clientY`: the bump eases toward its row.
  aim(clientY: number): void {
    const list = this.list();
    const rail = this.rail();
    if (!list || !rail) return;
    const box = list.getBoundingClientRect();
    const row = (clientY - box.top + list.scrollTop) / ROW_PITCH;
    this.target = Math.max(0, Math.min(this.rows(), row));
    const now = performance.now();
    if (!this.active) {
      // Arriving: the bump starts at the pointer, grown in from rest.
      this.active = true;
      this.focus = this.target;
      this.startedAt = now;
      this.lastAt = now;
    }
    if (this.frame !== undefined) return;
    rail.setAttribute(WAVE_ATTRIBUTE, "moving");
    this.frame = requestAnimationFrame(this.step);
  }

  /// The list scrolled under a still pointer at `clientY`: a running wave follows the row now under it.
  follow(clientY: number): void {
    if (this.active) this.aim(clientY);
  }

  /// The pointer left the ticks (or the wave is off): back to the rail's own transforms.
  leave(): void {
    if (this.frame !== undefined) cancelAnimationFrame(this.frame);
    this.frame = undefined;
    this.active = false;
    this.rail()?.removeAttribute(WAVE_ATTRIBUTE);
    for (const tick of this.written.keys()) tick.style.removeProperty(WAVE_PROPERTY);
    this.written.clear();
  }

  private readonly step = (time: number) => {
    this.frame = undefined;
    if (!this.active) return;
    // A frame's time can come before the event that asked for it; elapsed time is never negative.
    const now = Math.max(time, this.lastAt);
    this.focus = waveFollow(this.focus, this.target, now - this.lastAt);
    this.lastAt = now;
    const grown = now - this.startedAt;
    this.draw(waveAmplitude(grown));
    if (this.focus !== this.target || grown < WAVE_IN_MS) this.frame = requestAnimationFrame(this.step);
    else this.rail()?.setAttribute(WAVE_ATTRIBUTE, "still");
  };

  private draw(amplitude: number): void {
    const list = this.list();
    if (!list) return;
    const { reach } = this.shape;
    const first = Math.max(0, Math.floor(this.focus - reach));
    const last = Math.min(this.rows() - 1, Math.ceil(this.focus + reach));
    const seen = new Set<HTMLElement>();
    for (let index = first; index <= last; index += 1) {
      const tick = list.querySelector<HTMLElement>(`[data-tick="${index}"]`);
      if (!tick) continue;
      const value = Math.round(waveProgress(this.shape, index, this.focus, amplitude) * 10_000) / 10_000;
      if (value === 0) continue;
      seen.add(tick);
      if (this.written.get(tick) === value) continue;
      tick.style.setProperty(WAVE_PROPERTY, String(value));
      this.written.set(tick, value);
    }
    for (const tick of this.written.keys()) {
      if (seen.has(tick)) continue;
      tick.style.removeProperty(WAVE_PROPERTY);
      this.written.delete(tick);
    }
  }
}
