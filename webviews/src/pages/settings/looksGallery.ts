// Settings > Appearance > Looks (LooksGalleryCard): the pure parts of the card. The CLI owns the
// catalog, the previews, the stack and every write (`cmux setup gallery|preview|install|remove|on|
// off|order`); this reads its answers, says its consent card in the page's words, and works out the
// one list `order` takes.
import type { LookConsentCard, LooksGallery, LookPreview } from "./ops";
import { t } from "./strings";

/** What one `cmux.settings.looks` answer means: the verb's JSON, the consent card an install
 * without `yes` answers (nothing changed yet), or a refusal in the CLI's own words. */
export type LooksOutcome =
  | { kind: "value"; value: unknown }
  | { kind: "consent"; card: LookConsentCard }
  | { kind: "refusal"; code: string; message: string };

type Envelope = { code: string; message?: unknown; details?: unknown };

/** The CLI's error envelope in an answer: flat (`{code, message, details}`, what the host relays
 * from stderr) or wrapped (`{error: {...}}`); null for a verb's own JSON. */
function envelopeOf(answer: unknown): Envelope | null {
  if (typeof answer !== "object" || answer === null) return null;
  const wrapped = (answer as { error?: unknown }).error;
  const candidate = typeof wrapped === "object" && wrapped !== null ? wrapped : answer;
  return typeof (candidate as { code?: unknown }).code === "string" ? (candidate as Envelope) : null;
}

/** Whether `value` has the consent card's parts the card draws (a setup and a source commit). */
export function isConsentCard(value: unknown): value is LookConsentCard {
  if (typeof value !== "object" || value === null) return false;
  const card = value as Partial<LookConsentCard>;
  return (
    typeof card.setup?.id === "string" &&
    typeof card.setup.name === "string" &&
    typeof card.source?.reference === "string" &&
    typeof card.source.commit === "string" &&
    card.source.commit.length > 0
  );
}

/** Reads one answer of `cmux.settings.looks`. */
export function readLooksAnswer(answer: unknown): LooksOutcome {
  const envelope = envelopeOf(answer);
  if (!envelope) return { kind: "value", value: answer };
  if (envelope.code === "setup.needs_consent" && isConsentCard(envelope.details))
    return { kind: "consent", card: envelope.details };
  const message =
    typeof envelope.message === "string" && envelope.message
      ? envelope.message
      : t("settingsPage.looksGallery.notChanged");
  return { kind: "refusal", code: envelope.code, message };
}

/** The gallery listing in a verb's JSON, or null when it is not one. */
export function asGallery(value: unknown): LooksGallery | null {
  if (typeof value !== "object" || value === null) return null;
  const { looks, stack } = value as Partial<LooksGallery>;
  return Array.isArray(looks) && Array.isArray(stack) ? { looks, stack } : null;
}

/** The preview image in a verb's JSON, or null (no image: `setup.preview_missing`, or a bad answer). */
export function asPreview(value: unknown): LookPreview | null {
  if (typeof value !== "object" || value === null) return null;
  const preview = value as Partial<LookPreview>;
  return typeof preview.dataUrl === "string" && preview.dataUrl.startsWith("data:image/")
    ? (preview as LookPreview)
    : null;
}

/** What Install sends after the person confirms: the card's repo pinned to the commit the card
 * showed (`REPO@COMMIT`), so what installs is what they read, even if the repo moved since. */
export function pinnedReference(card: LookConsentCard): string {
  const reference = card.source.reference.replace(/@[^/@]*$/, "");
  return `${reference}@${card.source.commit}`;
}

/** The ids `order` takes after moving `id` one step (`by` -1 is up, toward the top), top first;
 * null when it is already at that edge or not in the stack. */
export function moveOrder(ids: readonly string[], id: string, by: -1 | 1): string[] | null {
  const from = ids.indexOf(id);
  const to = from + by;
  if (from < 0 || to < 0 || to >= ids.length) return null;
  const next = [...ids];
  next.splice(from, 1);
  next.splice(to, 0, id);
  return next;
}

/** A value from the card, as one short line of text (strings bare, everything else as JSON). */
function shown(value: unknown): string {
  return typeof value === "string" ? value : JSON.stringify(value);
}

/** What one file part is, in the page's words. */
function partLabel(card: LookConsentCard, part: string): string {
  switch (part) {
    case "settings":
      return t("settingsPage.looksGallery.part.settings");
    case "keybindings":
      return t("settingsPage.looksGallery.part.keybindings", card.setup.keybindings);
    case "themes":
      return t("settingsPage.looksGallery.part.themes");
    case "views":
      return t("settingsPage.looksGallery.part.views");
    case "styles":
      return t("settingsPage.looksGallery.part.styles");
    case "automations":
      return t("settingsPage.looksGallery.part.automations");
    default:
      return part;
  }
}

/** One line of what an install changes; `kind` groups them, `replaces` marks a thing of the
 * person's own it changes. */
export type ConsentLine = {
  kind: "theme" | "setting" | "file" | "action" | "extension";
  text: string;
  replaces: boolean;
};

/** Everything the consent card says the install changes, in the CLI card's order: theme, settings,
 * files (themes, views, stylesheets), actions, then extensions with their scopes. */
export function consentLines(card: LookConsentCard): ConsentLine[] {
  const lines: ConsentLine[] = [];
  const { setup } = card;
  if (setup.theme)
    lines.push({ kind: "theme", text: t("settingsPage.looksGallery.change.theme", setup.theme), replaces: false });
  for (const setting of setup.settings ?? []) {
    const replaces = setting.replaces !== undefined;
    lines.push({
      kind: "setting",
      text: replaces
        ? t("settingsPage.looksGallery.change.settingYours", setting.key, shown(setting.value), shown(setting.replaces))
        : t("settingsPage.looksGallery.change.setting", setting.key, shown(setting.value)),
      replaces,
    });
  }
  for (const file of setup.files ?? []) {
    lines.push({
      kind: "file",
      text: t("settingsPage.looksGallery.change.file", file.path, partLabel(card, file.part)),
      replaces: file.replaces,
    });
  }
  for (const action of setup.actions ?? []) {
    lines.push({
      kind: "action",
      text: t("settingsPage.looksGallery.change.action", action.name, action.runs),
      replaces: action.replaces,
    });
  }
  for (const extension of card.extensions ?? []) {
    const scopes =
      extension.scopes === null
        ? t("settingsPage.looksGallery.scopes.ownCard")
        : extension.scopes.length === 0
          ? t("settingsPage.looksGallery.scopes.none")
          : t("settingsPage.looksGallery.scopes.list", extension.scopes.join(", "));
    lines.push({
      kind: "extension",
      text: t(
        extension.installed
          ? "settingsPage.looksGallery.change.extensionInstalled"
          : "settingsPage.looksGallery.change.extension",
        extension.reference,
        scopes,
      ),
      replaces: false,
    });
  }
  return lines;
}

/** A commit's first 12 hex digits, as the CLI's card shows it. */
export function shortCommit(commit: string): string {
  return commit.slice(0, 12);
}
