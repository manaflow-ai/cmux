// Participant cursor palette. Index 0 is the host and uses the cmux brand
// gradient; 1..9 are distinct hues for viewers. The server assigns `color`
// as an index into this palette.

export interface ParticipantColor {
  /** Solid color used for chips, text, and avatar circles. */
  base: string;
  /** Gradient stops for the kite cursor fill (light to dark). */
  stops: string[];
}

function darken(hex: string, amount: number): string {
  const n = parseInt(hex.slice(1), 16);
  const r = Math.round(((n >> 16) & 0xff) * (1 - amount));
  const g = Math.round(((n >> 8) & 0xff) * (1 - amount));
  const b = Math.round((n & 0xff) * (1 - amount));
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, "0")}`;
}

function hueColor(base: string): ParticipantColor {
  return { base, stops: [base, darken(base, 0.35)] };
}

export const PARTICIPANT_PALETTE: ParticipantColor[] = [
  // 0: host — cmux gradient.
  { base: "#2d8cff", stops: ["#12c7f5", "#2d8cff", "#6c5cff"] },
  hueColor("#ff5c7a"), // 1 rose
  hueColor("#ffb020"), // 2 amber
  hueColor("#34d399"), // 3 green
  hueColor("#b163ff"), // 4 violet
  hueColor("#ff7a33"), // 5 orange
  hueColor("#14b8a6"), // 6 teal
  hueColor("#e879f9"), // 7 magenta
  hueColor("#a3e635"), // 8 lime
  hueColor("#60a5fa"), // 9 blue
];

export function participantColor(index: number): ParticipantColor {
  const palette = PARTICIPANT_PALETTE;
  const i = Number.isInteger(index) && index >= 0 ? index % palette.length : 0;
  return palette[i];
}

export function displayName(participant: {
  name?: string;
  email?: string;
}): string {
  if (participant.name && participant.name.trim().length > 0) {
    return participant.name.trim();
  }
  const email = participant.email ?? "";
  const at = email.indexOf("@");
  return at > 0 ? email.slice(0, at) : email;
}
