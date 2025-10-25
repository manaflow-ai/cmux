const ALPHABET_SIZE = 26;
const FIRST_LETTER_CHAR_CODE = "a".charCodeAt(0);
const DEFAULT_WORKSPACE_BASE = "workspace";

export function workspaceSequenceToName(sequence: number): string {
  if (sequence < 0) {
    throw new Error("Workspace sequence cannot be negative");
  }

  let value = sequence;
  let result = "";

  while (value >= 0) {
    const remainder = value % ALPHABET_SIZE;
    const char = String.fromCharCode(FIRST_LETTER_CHAR_CODE + remainder);
    result = char + result;
    value = Math.floor(value / ALPHABET_SIZE) - 1;
  }

  return result;
}

function sanitizeWorkspaceBaseName(
  baseName: string | null | undefined,
): string {
  if (!baseName) {
    return DEFAULT_WORKSPACE_BASE;
  }

  const trimmed = baseName.trim().toLowerCase();
  if (!trimmed) {
    return DEFAULT_WORKSPACE_BASE;
  }

  const replaced = trimmed.replace(/[^a-z0-9._-]+/g, "-");
  const normalized = replaced.replace(/^-+|-+$/g, "");
  return normalized || DEFAULT_WORKSPACE_BASE;
}

export function generateWorkspaceName({
  repoName,
  sequence,
}: {
  repoName?: string | null;
  sequence: number;
}): string {
  const suffix = workspaceSequenceToName(sequence);
  const base = sanitizeWorkspaceBaseName(repoName);
  return `${base}-${suffix}`;
}
