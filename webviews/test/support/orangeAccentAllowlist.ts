// schemas/theme/orange-accent-allowlist.json as the accent-glass scan reads it: the themes whose own accent may be
// orange (`allowed`), and the golden looks drawn orange by design (`looks`, each a looks.golden variant id). A look
// is honored only on its own looks.golden stage; test/orange-accent-allowlist.test.ts pins that it admits nothing else.
import fs from "node:fs";
import path from "node:path";

export type OrangeAccentAllowlist = { allowed: { name: string; themes: string[] }[]; looks?: { id: string }[] };

export const GOLDEN_LOOKS_ENTRY = "looks.golden";

export function readOrangeAccentAllowlist(webviews: string): OrangeAccentAllowlist {
  return JSON.parse(
    fs.readFileSync(path.join(webviews, "../schemas/theme/orange-accent-allowlist.json"), "utf8"),
  ) as OrangeAccentAllowlist;
}

/** Whether a stage may show an orange accent: its theme is an allowlisted one, or it is an allowlisted golden look's own stage. */
export function orangeAllowedFor(
  allowlist: OrangeAccentAllowlist,
): (stage: { entry: string; variant: string; theme: string | undefined }) => boolean {
  const themes = new Set(allowlist.allowed.flatMap((entry) => entry.themes));
  const looks = new Set((allowlist.looks ?? []).map((look) => look.id));
  return (stage) =>
    (stage.theme !== undefined && themes.has(stage.theme)) ||
    (stage.entry === GOLDEN_LOOKS_ENTRY && stage.theme === undefined && looks.has(stage.variant));
}
