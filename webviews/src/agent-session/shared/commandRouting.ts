export type ComposerCommandRoute = "explicit" | "detected" | null;

const commandNames = new Set([
  "cd",
  "clear",
  "echo",
  "history",
  "ls",
  "popd",
  "printenv",
  "pwd",
  "pushd",
  "type",
  "which",
]);

function looksLikeShellSyntax(input: string): boolean {
  return /^(?:\.|\.\.|~|\/)/.test(input);
}

/** Classifies only high-confidence shell input so ordinary prompts stay with the provider. */
export function composerCommandRoute(input: string): ComposerCommandRoute {
  const trimmed = input.trim();
  if (trimmed.length === 0) {
    return null;
  }
  if (trimmed.startsWith("!") && trimmed.slice(1).trim().length > 0) {
    return "explicit";
  }
  const firstWord = trimmed.match(/^[^\s]+/)?.[0]?.toLowerCase();
  if (firstWord && (commandNames.has(firstWord) || looksLikeShellSyntax(trimmed))) {
    return "detected";
  }
  return null;
}

export function commandText(input: string): string {
  const trimmed = input.trim();
  return trimmed.startsWith("!") ? trimmed.slice(1).trim() : trimmed;
}
