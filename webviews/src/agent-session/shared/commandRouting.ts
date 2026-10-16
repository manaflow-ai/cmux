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
  return /^(?:\.\/|\.\.\/|~\/|\/)/.test(input);
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


/**
 * Guards the one in-flight terminal command owned by a composer.
 *
 * A monotonically increasing input revision keeps a completed command from
 * clearing text typed after submission. The same gate also rejects repeated
 * activation while the native request is still pending.
 */
export class ComposerCommandSubmissionGate {
  private pendingRevision: number | null = null;

  begin(inputRevision: number): boolean {
    if (this.pendingRevision !== null) {
      return false;
    }
    this.pendingRevision = inputRevision;
    return true;
  }

  complete(submittedRevision: number, currentRevision: number): boolean {
    if (this.pendingRevision !== submittedRevision) {
      return false;
    }
    this.pendingRevision = null;
    return currentRevision === submittedRevision;
  }

  fail(submittedRevision: number): boolean {
    if (this.pendingRevision !== submittedRevision) {
      return false;
    }
    this.pendingRevision = null;
    return true;
  }

  get isPending(): boolean {
    return this.pendingRevision !== null;
  }
}
