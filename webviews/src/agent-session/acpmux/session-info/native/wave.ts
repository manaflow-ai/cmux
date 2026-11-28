/// Session Info's running wave is deliberately slower than the transcript's wave. Keep the
/// numbers here so the web row style and the native AppKit model cannot drift apart.
export const SESSION_INFO_WAVE_PERIOD_MS = 2_400;
// motion-allow: the wave's deliberately slower beat, shared with native
export const SESSION_INFO_WAVE_STEP_MS = 180;

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
