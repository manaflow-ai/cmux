// Settings › Import: every import suggestion card the host found on this Mac (CmuxNextImportCards,
// `import_suggestions` in the host lists, re-sent through cmux.settings.host.changed), dismissed
// ones dimmed with Show Again. Every text is localized by the host; a button runs the catalog
// action `import.card {id, action}`, the same path as the CLI's `cmux import card`.
import { useSettingsState, useStore } from "../context";
import { ImportCards, parseImportCards } from "../../../ui/ImportCards";

export function ImportSuggestionsCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const list = parseImportCards(host?.import_suggestions);
  if (!list) return null;
  return (
    <section className="group" data-card="importSuggestions">
      <ImportCards list={list} onAction={(id, action) => void store.runAction("import.card", { id, action })} />
    </section>
  );
}
