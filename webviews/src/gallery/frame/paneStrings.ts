// The agent pane's string tables on a stage, in the stage's language.
//
// The app's page head loads the tables before the pane's modules run, so acpmux/i18n.ts picks its
// language from them when it loads. A stage loads its entry's file first (to find the entry), and
// that file imports the pane's modules: i18n.ts then picked its language with no tables and the
// browser's own languages, before the frame set `navigator.languages` to the stage's `locale`, and
// kept English. Every pane entry drew English whatever its `locale` (harnesses-row-text measured
// the English words for "de" and "ja"). So the pane picks its language again once the tables are in.
import { addPseudoLocales } from "../pseudo";

/** Installs the pane's string tables (with the pseudo-locales) and switches the pane to the stage's language. */
export async function installPaneStrings(): Promise<void> {
  const strings = (await import("../../agent-session/acpmux/generated/strings.json")).default as unknown as Record<
    string,
    Record<string, string>
  >;
  addPseudoLocales(strings);
  globalThis.__cmuxPaneStrings = strings as never;
  const { paneLanguage, setPaneLanguage } = await import("../../agent-session/acpmux/i18n");
  setPaneLanguage(paneLanguage());
}
