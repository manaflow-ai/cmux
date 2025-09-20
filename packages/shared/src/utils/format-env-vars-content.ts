export type EnvVarEntry = {
  name: string;
  value: string;
};

function escapeDoubleQuotes(value: string): string {
  return value.replaceAll("\"", "\\\"");
}

function normalizeLineEndings(value: string): string {
  return value.replace(/\r\n?/g, "\n");
}

export function formatEnvVarsContent(entries: EnvVarEntry[]): string {
  const lines: string[] = [];

  for (const entry of entries) {
    const key = entry.name.trim();
    if (key.length === 0) {
      continue;
    }

    const rawValue = entry.value ?? "";
    const normalizedValue = normalizeLineEndings(rawValue);
    const escapedValue = escapeDoubleQuotes(normalizedValue);
    lines.push(`${key}="${escapedValue}"`);
  }

  return lines.join("\n");
}
