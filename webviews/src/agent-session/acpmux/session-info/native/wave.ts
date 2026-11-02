import type { CSSProperties } from "react";

/// Session Info's running wave is deliberately slower than the transcript's wave. Keep the
/// numbers here so the web row style and the native AppKit model cannot drift apart.
export const SESSION_INFO_WAVE_PERIOD_MS = 2_400;
export const SESSION_INFO_WAVE_STEP_MS = 180;

/// The CSS variables consumed by `ui/wave.css`. The native panel receives the same values through
/// each row's `wave` payload below.
export const SESSION_INFO_WAVE_STYLE: CSSProperties & Record<"--cmux-wave-period" | "--cmux-wave-step", string> = {
  "--cmux-wave-period": `${SESSION_INFO_WAVE_PERIOD_MS}ms`,
  "--cmux-wave-step": `${SESSION_INFO_WAVE_STEP_MS}ms`,
};

export type NativeInfoWave = {
  index: number;
  periodMs: number;
  stepMs: number;
};

export const nativeInfoWave = (index: number): NativeInfoWave => ({
  index,
  periodMs: SESSION_INFO_WAVE_PERIOD_MS,
  stepMs: SESSION_INFO_WAVE_STEP_MS,
});
