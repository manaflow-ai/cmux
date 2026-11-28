// Ghostty's theme value (appearance.theme): one theme name, or `light:A,dark:B` for a pair that
// follows the system appearance. The Theme section reads and writes it in this form.

export type ThemeSpec = { kind: "single"; name: string } | { kind: "pair"; light: string; dark: string };

export function parseThemeSpec(value: unknown): ThemeSpec | null {
  if (typeof value !== "string" || value.trim() === "") return null;
  const parts = value.split(",").map((part) => part.trim());
  const side = (prefix: string) =>
    parts
      .find((part) => part.toLowerCase().startsWith(`${prefix}:`))
      ?.slice(prefix.length + 1)
      .trim();
  const light = side("light");
  const dark = side("dark");
  if (light !== undefined || dark !== undefined) return { kind: "pair", light: light ?? dark!, dark: dark ?? light! };
  return { kind: "single", name: value.trim() };
}

export function formatThemeSpec(spec: ThemeSpec): string {
  return spec.kind === "single" ? spec.name : `light:${spec.light},dark:${spec.dark}`;
}

/** The theme name the spec shows in `scheme`. */
export function themeFor(spec: ThemeSpec | null, scheme: "light" | "dark", fallback: string): string {
  if (!spec) return fallback;
  return spec.kind === "single" ? spec.name : spec[scheme];
}
