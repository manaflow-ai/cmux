/**
 * Centralized color/style tokens for the cmux101 TUI.
 */

export const theme = {
  user: "cyan",
  assistant: "white",
  thinking: "gray",
  toolName: "yellow",
  toolError: "red",
  system: "blue",
  dim: "gray",
  accent: "magenta",
  success: "green",
} as const;

export type ThemeColor = (typeof theme)[keyof typeof theme];

/**
 * Role badge prefixes shown before each message.
 */
export function prefix(role: "user" | "assistant" | "tool" | "system"): string {
  switch (role) {
    case "user":
      return "▶ you";
    case "assistant":
      return "● assistant";
    case "tool":
      return "● tool";
    case "system":
      return "● system";
  }
}
