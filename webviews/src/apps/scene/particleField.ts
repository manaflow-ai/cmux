// The `Particles` node's simulation (cmux-app-host js/ABI.md "Motion"): plain numbers stepped by the
// canvas loop in SceneParticles.tsx, one field per node. No DOM here, so it is tested on its own.

export const PARTICLE_PRESETS = ["confetti", "sparkles", "rain", "snow", "embers", "stars"] as const;
export type ParticlePreset = (typeof PARTICLE_PRESETS)[number];

export const particlePreset = (value: unknown): ParticlePreset | undefined =>
  typeof value === "string" && (PARTICLE_PRESETS as readonly string[]).includes(value)
    ? (value as ParticlePreset)
    : undefined;

/** Each preset's own inks, used when the app passes no `colors`. Fixed hues: confetti and embers
 * read as themselves on any theme, as the native renderer's do. */
export const PARTICLE_COLORS: Record<ParticlePreset, readonly string[]> = {
  confetti: ["#FF5E5B", "#FFD93D", "#6BCB77", "#4D96FF", "#C77DFF", "#FF9F1C"], // colour-allow: a particle preset's fixed art inks, the same on every theme and the native renderer
  sparkles: ["#FFF6D5", "#FFD86B", "#FFFFFF"], // colour-allow: a particle preset's fixed art inks, the same on every theme and the native renderer
  rain: ["#9DB7D6", "#B8CCE4"], // colour-allow: a particle preset's fixed art inks, the same on every theme and the native renderer
  snow: ["#FFFFFF", "#EEF4FF"], // colour-allow: a particle preset's fixed art inks, the same on every theme and the native renderer
  embers: ["#FF9A3C", "#FF5F1F", "#FFC66B"], // colour-allow: a particle preset's fixed art inks, the same on every theme and the native renderer
  stars: ["#FFFFFF", "#CFE3FF", "#FFF1C9"], // colour-allow: a particle preset's fixed art inks, the same on every theme and the native renderer
};

/** Particles per second at `rate` 1 for a 320 x 200 field (scaled by area); confetti emits only on a burst. */
const EMIT_PER_SECOND: Record<ParticlePreset, number> = {
  confetti: 0,
  sparkles: 5,
  rain: 70,
  snow: 14,
  embers: 9,
  stars: 4,
};
const BASE_AREA = 320 * 200;
/** A field never holds more than this many particles, whatever the rate and the burst count. */
export const MAX_PARTICLES = 600;

type Particle = {
  x: number;
  y: number;
  vx: number;
  vy: number;
  age: number;
  life: number;
  size: number;
  color: string;
  spin: number;
  angle: number;
  /** Per-particle phase for sway and twinkle. */
  phase: number;
};

export type ParticleShape =
  | { kind: "rect"; x: number; y: number; w: number; h: number; angle: number; color: string; alpha: number }
  | { kind: "dot"; x: number; y: number; r: number; color: string; alpha: number; glow: boolean }
  | { kind: "line"; x: number; y: number; dx: number; dy: number; color: string; alpha: number; width: number }
  | { kind: "star"; x: number; y: number; r: number; color: string; alpha: number };

export class ParticleField {
  readonly particles: Particle[] = [];
  width = 0;
  height = 0;
  rate = 1;
  colors: readonly string[];
  private debt = 0;
  private time = 0;

  constructor(
    readonly preset: ParticlePreset,
    colors?: readonly string[] | null,
    private readonly random: () => number = Math.random,
  ) {
    this.colors = colors && colors.length ? colors : PARTICLE_COLORS[preset];
  }

  setColors(colors?: readonly string[] | null): void {
    this.colors = colors && colors.length ? colors : PARTICLE_COLORS[this.preset];
  }

  /** `rate` is the app's multiplier, clamped to [0, 4]. */
  setRate(rate: number | undefined): void {
    this.rate = rate === undefined || !Number.isFinite(rate) ? 1 : Math.min(Math.max(rate, 0), 4);
  }

  resize(width: number, height: number): void {
    this.width = Math.max(0, width);
    this.height = Math.max(0, height);
  }

  /** Whether the field emits on its own (a continuous preset at a rate above 0). */
  get continuous(): boolean {
    return EMIT_PER_SECOND[this.preset] > 0 && this.rate > 0;
  }

  /** Whether a frame would draw anything or change anything. */
  get active(): boolean {
    return this.particles.length > 0 || (this.continuous && this.width > 0 && this.height > 0);
  }

  /** Fills the field as if it had run for `seconds`, so a continuous preset opens full. */
  prewarm(seconds: number): void {
    if (!this.continuous) return;
    const step = 1 / 20;
    for (let t = 0; t < seconds; t += step) this.step(step);
  }

  private pick<T>(items: readonly T[]): T {
    return items[Math.floor(this.random() * items.length) % items.length]!;
  }

  private between(low: number, high: number): number {
    return low + (high - low) * this.random();
  }

  private add(particle: Omit<Particle, "age" | "phase" | "angle" | "spin"> & Partial<Particle>): void {
    if (this.particles.length >= MAX_PARTICLES) return;
    this.particles.push({ age: 0, phase: this.random() * Math.PI * 2, angle: 0, spin: 0, ...particle });
  }

  /** One continuous particle of the preset. */
  private emit(): void {
    const { width: w, height: h } = this;
    const color = this.pick(this.colors);
    switch (this.preset) {
      case "sparkles":
        this.add({
          x: this.between(0, w),
          y: this.between(0, h),
          vx: 0,
          vy: this.between(-6, -2),
          life: this.between(0.7, 1.4),
          size: this.between(2, 4.5),
          color,
        });
        return;
      case "rain":
        this.add({
          x: this.between(0, w + h * 0.15),
          y: this.between(-24, -4),
          vx: -70,
          vy: this.between(620, 900),
          life: 4,
          size: this.between(10, 18),
          color,
        });
        return;
      case "snow":
        this.add({
          x: this.between(-10, w + 10),
          y: this.between(-12, -2),
          vx: 0,
          vy: this.between(18, 42),
          life: (h + 40) / 18,
          size: this.between(1.2, 3.2),
          color,
          spin: this.between(0.5, 1.3),
        });
        return;
      case "embers":
        this.add({
          x: this.between(0, w),
          y: h + this.between(0, 6),
          vx: this.between(-8, 8),
          vy: this.between(-70, -28),
          life: this.between(1.8, 3.6),
          size: this.between(1, 2.6),
          color,
          spin: this.between(1, 2.5),
        });
        return;
      case "stars":
        this.add({
          x: this.between(0, w),
          y: this.between(0, h),
          vx: 0,
          vy: 0,
          life: this.between(2, 5),
          size: this.between(0.6, 1.8),
          color,
        });
        return;
      case "confetti":
        return;
    }
  }

  /** One burst: confetti from the top, sparkles from the center, any other preset a dense spray of its own. */
  burst(): void {
    const { width: w, height: h } = this;
    if (w <= 0 || h <= 0) return;
    if (this.preset === "confetti") {
      for (let i = 0; i < 110; i += 1) {
        this.add({
          x: this.between(w * 0.1, w * 0.9),
          y: this.between(-h * 0.25, -4),
          vx: this.between(-60, 60),
          vy: this.between(40, 170),
          life: this.between(2.4, 3.6),
          size: this.between(5, 9),
          color: this.pick(this.colors),
          angle: this.between(0, Math.PI * 2),
          spin: this.between(-9, 9),
        });
      }
      return;
    }
    if (this.preset === "sparkles") {
      for (let i = 0; i < 40; i += 1) {
        const angle = this.between(0, Math.PI * 2);
        const speed = this.between(50, 190);
        this.add({
          x: w / 2,
          y: h / 2,
          vx: Math.cos(angle) * speed,
          vy: Math.sin(angle) * speed,
          life: this.between(0.6, 1.1),
          size: this.between(2.5, 5),
          color: this.pick(this.colors),
        });
      }
      return;
    }
    for (let i = 0; i < 40; i += 1) this.emit();
  }

  /** Advances the field by `dt` seconds (already scaled by ui.animationSpeed). */
  step(dt: number): void {
    if (dt <= 0) return;
    this.time += dt;
    if (this.continuous && this.width > 0 && this.height > 0) {
      const area = Math.max(this.width * this.height, 1) / BASE_AREA;
      this.debt += EMIT_PER_SECOND[this.preset] * this.rate * Math.min(Math.max(area, 0.25), 6) * dt;
      while (this.debt >= 1) {
        this.debt -= 1;
        this.emit();
      }
    }
    const { width: w, height: h } = this;
    let kept = 0;
    for (const p of this.particles) {
      p.age += dt;
      switch (this.preset) {
        case "confetti":
          p.vy += 260 * dt;
          p.vx *= 1 - 1.2 * dt;
          p.vy *= 1 - 0.9 * dt;
          p.x += (p.vx + Math.sin(this.time * 4 + p.phase) * 22) * dt;
          p.y += p.vy * dt;
          p.angle += p.spin * dt;
          break;
        case "sparkles":
          p.vx *= 1 - 3 * dt;
          p.vy *= 1 - 3 * dt;
          p.x += p.vx * dt;
          p.y += p.vy * dt;
          break;
        case "snow":
          p.x += Math.sin(this.time * p.spin + p.phase) * 14 * dt;
          p.y += p.vy * dt;
          break;
        case "embers":
          p.x += (p.vx + Math.sin(this.time * p.spin + p.phase) * 12) * dt;
          p.y += p.vy * dt;
          break;
        default:
          p.x += p.vx * dt;
          p.y += p.vy * dt;
      }
      const gone = p.age >= p.life || p.y > h + 30 || p.y < -h - 40 || p.x < -60 || p.x > w + 60;
      if (!gone) this.particles[kept++] = p;
    }
    this.particles.length = kept;
  }

  /** What one frame draws, in field points. */
  shapes(): ParticleShape[] {
    const out: ParticleShape[] = [];
    for (const p of this.particles) {
      const t = p.life > 0 ? p.age / p.life : 1;
      switch (this.preset) {
        case "confetti": {
          const alpha = t > 0.8 ? (1 - t) / 0.2 : 1;
          // A flat piece turning in 3D: its height swings with the flutter.
          const turn = Math.abs(Math.cos(this.time * 6 + p.phase));
          out.push({
            kind: "rect",
            x: p.x,
            y: p.y,
            w: p.size,
            h: p.size * 0.45 * (0.25 + turn * 0.75),
            angle: p.angle,
            color: p.color,
            alpha,
          });
          break;
        }
        case "sparkles":
          out.push({
            kind: "star",
            x: p.x,
            y: p.y,
            r: p.size * (0.6 + 0.4 * Math.sin(Math.PI * t)),
            color: p.color,
            alpha: Math.sin(Math.PI * t),
          });
          break;
        case "rain":
          out.push({
            kind: "line",
            x: p.x,
            y: p.y,
            dx: (p.vx / p.vy) * p.size,
            dy: p.size,
            color: p.color,
            alpha: 0.5,
            width: 1,
          });
          break;
        case "snow":
          out.push({ kind: "dot", x: p.x, y: p.y, r: p.size, color: p.color, alpha: 0.85, glow: false });
          break;
        case "embers":
          out.push({
            kind: "dot",
            x: p.x,
            y: p.y,
            r: p.size,
            color: p.color,
            alpha: (1 - t) * (0.7 + 0.3 * Math.sin(this.time * 9 + p.phase)),
            glow: true,
          });
          break;
        case "stars":
          out.push({
            kind: "dot",
            x: p.x,
            y: p.y,
            r: p.size,
            color: p.color,
            alpha: Math.sin(Math.PI * t) * (0.75 + 0.25 * Math.sin(this.time * 5 + p.phase)),
            glow: p.size > 1.3,
          });
          break;
      }
    }
    return out;
  }
}

/** Draws one frame of shapes onto a 2D context already scaled to field points. */
export function drawParticles(
  ctx: CanvasRenderingContext2D,
  shapes: readonly ParticleShape[],
  width: number,
  height: number,
): void {
  ctx.clearRect(0, 0, width, height);
  for (const s of shapes) {
    if (s.alpha <= 0) continue;
    ctx.globalAlpha = Math.min(1, s.alpha);
    ctx.fillStyle = s.color;
    ctx.strokeStyle = s.color;
    switch (s.kind) {
      case "rect":
        ctx.save();
        ctx.translate(s.x, s.y);
        ctx.rotate(s.angle);
        ctx.fillRect(-s.w / 2, -s.h / 2, s.w, s.h);
        ctx.restore();
        break;
      case "dot":
        if (s.glow) {
          ctx.globalAlpha = Math.min(1, s.alpha) * 0.25;
          ctx.beginPath();
          ctx.arc(s.x, s.y, s.r * 3, 0, Math.PI * 2);
          ctx.fill();
          ctx.globalAlpha = Math.min(1, s.alpha);
        }
        ctx.beginPath();
        ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
        ctx.fill();
        break;
      case "line":
        ctx.lineWidth = s.width;
        ctx.beginPath();
        ctx.moveTo(s.x, s.y);
        ctx.lineTo(s.x + s.dx, s.y + s.dy);
        ctx.stroke();
        break;
      case "star": {
        // A four-point sparkle: two thin diamonds crossed.
        const r = s.r;
        const k = r * 0.28;
        ctx.beginPath();
        ctx.moveTo(s.x, s.y - r);
        ctx.lineTo(s.x + k, s.y - k);
        ctx.lineTo(s.x + r, s.y);
        ctx.lineTo(s.x + k, s.y + k);
        ctx.lineTo(s.x, s.y + r);
        ctx.lineTo(s.x - k, s.y + k);
        ctx.lineTo(s.x - r, s.y);
        ctx.lineTo(s.x - k, s.y - k);
        ctx.closePath();
        ctx.fill();
        break;
      }
    }
  }
  ctx.globalAlpha = 1;
}
