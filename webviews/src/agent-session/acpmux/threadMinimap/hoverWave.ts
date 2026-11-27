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
import { reducedMotion } from "./scrollMotion";
import {
  ROW_PITCH,
  waveAmplitude,
  waveFollow,
  WAVE_IN_MS,
  waveProgress,
  type WaveShape,
  type ZipMotion,
  zipRetarget,
  zipSettled,
  zipStep,
} from "./model";

/// The custom property the bar (and bookmark dot) of each tick in the bump's reach carries: its
/// magnification, 0 to 1. Set on the bar and dot themselves, not the tick, so a write restyles only
/// them and nothing inherits it.
export const WAVE_PROPERTY = "--acpmux-minimap-wave";
/// The rail's attribute while the wave draws its ticks (threadMinimap.css).
export const WAVE_ATTRIBUTE = "data-wave";
/// The loop's state on the rail, `moving` or `still` (the gallery and the tests wait on it). No
/// selector reads it, so the loop starting and stopping restyles nothing; toggling `data-wave` itself
/// would restyle every tick in the rail.
export const WAVE_STATE_ATTRIBUTE = "data-wave-state";

/// The tick's parts the wave draws (threadMinimap.css).
const PARTS = ["acpmux-minimap__bar", "acpmux-minimap__dot"];

export class HoverWave {
  private frame: number | undefined;
  /// The bump's fractional row now, and the pointer's it eases toward.
  private focus = 0;
  private target = 0;
  private active = false;
  private startedAt = 0;
  private lastAt = 0;
  /// The bars and dots carrying the property, with the value each was last given.
  private readonly written = new Map<HTMLElement, number>();

  constructor(
    private readonly shape: WaveShape,
    private readonly rail: () => HTMLElement | null,
    private readonly list: () => HTMLElement | null,
    private readonly rows: () => number,
    private readonly pitch = ROW_PITCH,
  ) {}

  /// The pointer is over the ticks at `clientY`: the bump eases toward its row.
  aim(clientY: number): void {
    const list = this.list();
    const rail = this.rail();
    if (!list || !rail) return;
    // A rail that mounted again (shown again, or back from the full map) under a pointer that never
    // left: the wave starts over on it rather than writing to the old rail's ticks.
    if (this.active && !rail.hasAttribute(WAVE_ATTRIBUTE)) this.leave();
    // Reduce Motion read live as the pointer arrives (the rail's own state updates on the tick's
    // enter, which comes after this): the stepped fisheye, which switches at once, draws instead.
    if (!this.active && reducedMotion()) return;
    const box = list.getBoundingClientRect();
    const row = (clientY - box.top + list.scrollTop) / this.pitch;
    this.target = Math.max(0, Math.min(this.rows(), row));
    const now = performance.now();
    if (!this.active) {
      // Arriving: the bump starts at the pointer, grown in from rest.
      this.active = true;
      this.focus = this.target;
      this.startedAt = now;
      this.lastAt = now;
      rail.setAttribute(WAVE_ATTRIBUTE, "");
    }
    if (this.frame !== undefined) return;
    rail.setAttribute(WAVE_STATE_ATTRIBUTE, "moving");
    this.frame = requestAnimationFrame(this.step);
  }

  /// The list scrolled under a still pointer at `clientY`: a running wave follows the row now under it.
  follow(clientY: number): void {
    if (this.active) this.aim(clientY);
  }

  /// The pointer left the ticks: this wave hands them back to the rail's own transforms at once.
  release(): void {
    this.leave();
  }

  /// The pointer left the ticks (or the wave is off): back to the rail's own transforms.
  leave(): void {
    if (this.frame !== undefined) cancelAnimationFrame(this.frame);
    this.frame = undefined;
    this.active = false;
    const rail = this.rail();
    rail?.removeAttribute(WAVE_ATTRIBUTE);
    rail?.removeAttribute(WAVE_STATE_ATTRIBUTE);
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
    else this.rail()?.setAttribute(WAVE_STATE_ATTRIBUTE, "still");
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
      // To a thousandth (0.02 px of a tick), so the follow's last frames write nothing they cannot show.
      const value = Math.round(waveProgress(this.shape, index, this.focus, amplitude) * 1000) / 1000;
      if (value === 0) continue;
      for (const part of tick.children) {
        if (!(part instanceof HTMLElement) || !PARTS.some((name) => part.classList.contains(name))) continue;
        seen.add(part);
        if (this.written.get(part) === value) continue;
        part.style.setProperty(WAVE_PROPERTY, String(value));
        this.written.set(part, value);
      }
    }
    for (const tick of this.written.keys()) {
      if (seen.has(tick)) continue;
      tick.style.removeProperty(WAVE_PROPERTY);
      this.written.delete(tick);
    }
  }
}

/// The clock the zipper runs on: the page's, or one the gallery sets on the window
/// (`__cmuxRailWaveClock`) to hold a frame mid-sweep or mid-release for its capture.
function zipClock(): number {
  const held = (globalThis as { __cmuxRailWaveClock?: () => number }).__cmuxRailWaveClock;
  return held ? held() : performance.now();
}

/// The zipper (wave.experiment.ts `zipper`, the default): each tick its own discrete length by whole
/// rows from the hovered row (model.ts `zipTargets`), each running its own ease from where it is to
/// its new length as the hovered row changes (`zipRetarget`), the hovered tick always the single
/// longest (`zipStep`). Leaving the rail shrinks every tick back to rest on the same loop instead of
/// at once. It writes the same property the wave does, so threadMinimap.css draws both alike.
//
// Loop: one requestAnimationFrame at a time, asked for when the hovered row changes or the pointer
// leaves. It stops once every tick has reached its target; after a release that also clears the
// rail's attribute and every property it wrote. `leave()` (Reduce Motion, the rail going, unmount)
// cancels a pending frame and clears everything at once.
export class ZipperWave {
  private frame: number | undefined;
  /// The hovered row; undefined while releasing or off.
  private hovered: number | undefined;
  private on = false;
  /// Each moving or magnified tick's motion, by row.
  private readonly motions = new Map<number, ZipMotion>();
  private readonly written = new Map<HTMLElement, number>();

  constructor(
    private readonly rail: () => HTMLElement | null,
    private readonly list: () => HTMLElement | null,
    private readonly rows: () => number,
    private readonly pitch = ROW_PITCH,
  ) {}

  /// The pointer is over the ticks at `clientY`: the row under it becomes the hovered one.
  aim(clientY: number): void {
    const list = this.list();
    const rail = this.rail();
    if (!list || !rail) return;
    // A rail that mounted again under a pointer that never left starts over on the new rail.
    if (this.on && !rail.hasAttribute(WAVE_ATTRIBUTE)) this.leave();
    // Reduce Motion: the stepped fisheye, which switches at once, draws instead.
    if (!this.on && reducedMotion()) return;
    const rows = this.rows();
    if (rows <= 0) return;
    const box = list.getBoundingClientRect();
    const row = Math.max(0, Math.min(rows - 1, Math.floor((clientY - box.top + list.scrollTop) / this.pitch)));
    if (!this.on) {
      this.on = true;
      rail.setAttribute(WAVE_ATTRIBUTE, "");
    }
    if (row === this.hovered) return;
    this.hovered = row;
    zipRetarget(this.motions, row, rows, zipClock());
    this.schedule(rail);
  }

  /// The list scrolled under a still pointer at `clientY`: the hovered row follows it.
  follow(clientY: number): void {
    if (this.hovered !== undefined) this.aim(clientY);
  }

  /// The pointer left the ticks: every tick shrinks back to rest, then the rail's own transforms
  /// take over. Under Reduce Motion it is at once.
  release(): void {
    if (!this.on) return;
    const rail = this.rail();
    if (!rail || reducedMotion()) return this.leave();
    this.hovered = undefined;
    zipRetarget(this.motions, undefined, this.rows(), zipClock());
    this.schedule(rail);
  }

  /// Off at once: back to the rail's own transforms.
  leave(): void {
    if (this.frame !== undefined) cancelAnimationFrame(this.frame);
    this.frame = undefined;
    this.on = false;
    this.hovered = undefined;
    this.motions.clear();
    const rail = this.rail();
    rail?.removeAttribute(WAVE_ATTRIBUTE);
    rail?.removeAttribute(WAVE_STATE_ATTRIBUTE);
    for (const part of this.written.keys()) part.style.removeProperty(WAVE_PROPERTY);
    this.written.clear();
  }

  private schedule(rail: HTMLElement): void {
    if (this.frame !== undefined) return;
    rail.setAttribute(WAVE_STATE_ATTRIBUTE, "moving");
    this.frame = requestAnimationFrame(this.step);
  }

  private readonly step = () => {
    this.frame = undefined;
    if (!this.on) return;
    const now = zipClock();
    const values = zipStep(this.motions, this.hovered, now);
    this.draw(values);
    // Ticks back at rest drop out; their property is already gone (`draw`).
    for (const [index, motion] of this.motions)
      if (motion.to === 0 && now - motion.start >= motion.ms) this.motions.delete(index);
    if (!zipSettled(this.motions, now)) this.frame = requestAnimationFrame(this.step);
    else if (this.hovered === undefined) this.leave();
    else this.rail()?.setAttribute(WAVE_STATE_ATTRIBUTE, "still");
  };

  private draw(values: Map<number, number>): void {
    const list = this.list();
    if (!list) return;
    const seen = new Set<HTMLElement>();
    for (const [index, raw] of values) {
      // To a thousandth (0.02 px of a tick), so the ease's last frames write nothing they cannot show.
      const value = Math.round(raw * 1000) / 1000;
      if (value === 0) continue;
      const tick = list.querySelector<HTMLElement>(`[data-tick="${index}"]`);
      if (!tick) continue;
      for (const part of tick.children) {
        if (!(part instanceof HTMLElement) || !PARTS.some((name) => part.classList.contains(name))) continue;
        seen.add(part);
        if (this.written.get(part) === value) continue;
        part.style.setProperty(WAVE_PROPERTY, String(value));
        this.written.set(part, value);
      }
    }
    for (const part of this.written.keys()) {
      if (seen.has(part)) continue;
      part.style.removeProperty(WAVE_PROPERTY);
      this.written.delete(part);
    }
  }
}
