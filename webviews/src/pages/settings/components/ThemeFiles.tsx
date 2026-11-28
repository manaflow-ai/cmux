// Save as Ghostty Theme and Import Theme File (cx-wqn5.1): the theme in the preview, with its edits,
// becomes a Ghostty theme file in the person's themes folder, or a theme file they pick is copied
// there. Either one is then picked as the terminal theme. A name in use asks inline before replacing.
import { useState, type FormEvent } from "react";
import type { WireError } from "../ops";
import { useStore } from "../context";
import { t } from "../strings";
import type { Reply } from "../store";

type Prompt =
  | { kind: "name"; value: string }
  | { kind: "replace"; name: string; again: Retry; details: WireError["details"] };
/** The same save or import again, for a refusal's details (an import's token); `replace` replaces. */
type Retry = (details: WireError["details"]) => (replace: boolean) => Promise<Reply<{ name?: string }>>;

const refusals: Record<string, string> = {
  "cmux.settings.theme.invalid_name": "settingsPage.theme.file.invalidName",
  "cmux.settings.theme.shipped_name": "settingsPage.theme.file.shippedName",
  "cmux.settings.theme.not_a_theme": "settingsPage.theme.file.notATheme",
};

// The name field takes focus when it opens (a stable ref, so only on mount).
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

export function ThemeFiles({
  base,
  disabled,
  canSave,
  onSaved,
}: {
  base: string;
  disabled: boolean;
  /** Whether the previewed theme has a file to save from (not the Ghostty config's own colors). */
  canSave: boolean;
  /** Picks the saved or imported theme. */
  onSaved: (name: string) => Promise<unknown>;
}) {
  const store = useStore();
  const [prompt, setPrompt] = useState<Prompt | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const finish = async (reply: Reply<{ name?: string }>, again: Retry) => {
    if (reply.ok) {
      setPrompt(null);
      setError(null);
      if (reply.value.name) await onSaved(reply.value.name);
      return;
    }
    const { code, details } = reply.error as WireError;
    if (code === "cmux.settings.theme.exists") {
      const name = typeof details?.name === "string" ? details.name : "";
      setPrompt({ kind: "replace", name, again, details });
      setError(null);
      return;
    }
    setError(refusals[code] ? t(refusals[code]) : reply.error.message);
  };
  const run = async (work: () => Promise<void>) => {
    setBusy(true);
    try {
      await work();
    } finally {
      setBusy(false);
    }
  };
  const save =
    (name: string): Retry =>
    () =>
    (replace) =>
      store.saveThemeFile(name, base, replace);
  // An import retries with the token of the refusal it answers.
  const reimport: Retry = (details) => (replace) =>
    store.importThemeFile({ token: typeof details?.token === "string" ? details.token : "", replace });
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (prompt?.kind !== "name") return;
    const name = prompt.value.trim();
    void run(async () => finish(await save(name)(undefined)(false), save(name)));
  };
  const importFile = () =>
    void run(async () => {
      setPrompt(null);
      await finish(await store.importThemeFile(), reimport);
    });

  return (
    <div className="theme-files" data-theme-files="">
      {prompt?.kind === "name" ? (
        <form className="theme-files-row" onSubmit={submit} data-theme-files-prompt="name">
          <input
            className="field"
            aria-label={t("settingsPage.theme.file.name")}
            ref={focusOnMount}
            spellCheck={false}
            value={prompt.value}
            onChange={(event) => setPrompt({ kind: "name", value: event.target.value })}
          />
          <button type="submit" className="button" disabled={busy || prompt.value.trim() === ""}>
            {t("settingsPage.theme.file.save")}
          </button>
          <button
            type="button"
            className="button"
            onClick={() => {
              setPrompt(null);
              setError(null);
            }}
          >
            {t("settingsPage.cancel")}
          </button>
        </form>
      ) : prompt?.kind === "replace" ? (
        <div className="theme-files-row" data-theme-files-prompt="replace">
          <span>{t("settingsPage.theme.file.replace", prompt.name)}</span>
          <button
            type="button"
            className="button danger"
            disabled={busy}
            onClick={() => void run(async () => finish(await prompt.again(prompt.details)(true), prompt.again))}
          >
            {t("settingsPage.theme.file.replaceButton")}
          </button>
          <button type="button" className="button" onClick={() => setPrompt(null)}>
            {t("settingsPage.cancel")}
          </button>
        </div>
      ) : (
        <div className="theme-files-row">
          <button
            type="button"
            className="button"
            disabled={disabled || busy || !canSave}
            data-theme-files-action="save"
            onClick={() => {
              setError(null);
              setPrompt({ kind: "name", value: t("settingsPage.theme.file.defaultName", base) });
            }}
          >
            {t("settingsPage.theme.file.saveAs")}
          </button>
          <button
            type="button"
            className="button"
            disabled={disabled || busy}
            data-theme-files-action="import"
            onClick={importFile}
          >
            {t("settingsPage.theme.file.import")}
          </button>
        </div>
      )}
      {error && (
        <div className="row-error" data-theme-files-error="">
          {error}
        </div>
      )}
    </div>
  );
}
