// Participant palette shared by cursors, chat, carets, and presence dots.
// Index 0 is always the host; the worker assigns 1..7 in join order and wraps.
// Hues are spaced for distinguishability on the dark workspace background.

export const PARTICIPANT_COLORS = [
  "#2d8cff", // host blue (cmux brand mid)
  "#ff5c93",
  "#3ecf6e",
  "#ffb02e",
  "#b06cff",
  "#00c2c7",
  "#ff7a45",
  "#e0d75a",
] as const;

export function participantColor(index: number): string {
  return PARTICIPANT_COLORS[
    ((index % PARTICIPANT_COLORS.length) + PARTICIPANT_COLORS.length) %
      PARTICIPANT_COLORS.length
  ] as string;
}
