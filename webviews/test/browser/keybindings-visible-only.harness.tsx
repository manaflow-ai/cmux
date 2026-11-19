// l10n-allow-file: bench fixture titles, not shipped UI.
// The real Keyboard Shortcuts page over N actions (`#n=10000`), for
// bench/keybindings-visible-only.bench.ts: a stand-in app that answers every list with all N as new
// objects (as the app does) and lets the bench change one action. `benchRowRenders` counts the rows
// that rendered since its last mark, read from each mounted row's fiber
// (test/support/mountedRowRenders.ts), so the page carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/transientMaterial";
import "../../src/ui/ui.css";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/keybindings/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/keybindings/generated/strings.json";
import { KeybindingsPage } from "../../src/pages/keybindings/KeybindingsPage";
import { MockKeybindingsProvider } from "../../src/pages/keybindings/mockProvider";
import { KeybindingsStore } from "../../src/pages/keybindings/store";
import { KeybindingOps, type Binding, type BindingListResult } from "../../src/pages/keybindings/types";
import { UiProvider } from "../../src/ui/UiProvider";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th action's `when` and has the page read the table again. */
    benchChangeOne(index: number): Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);

class ManyActions extends MockKeybindingsProvider {
  table: Binding[] = Array.from({ length: n }, (_, index) => ({
    id: index,
    key: `cmd+k ${index}`,
    display: `⌘K ${index}`,
    command: `action.${index}`,
    title: `Action ${String(index).padStart(5, "0")} that does something worth a key`,
    when: index % 3 ? null : "terminalFocus",
    source: "default" as const,
    conflicts: [],
  }));
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op !== KeybindingOps.list) return super.call<R>(op, params);
    return {
      bindings: this.table.map((binding) => ({ ...binding, conflicts: [...binding.conflicts] })),
    } satisfies BindingListResult as R;
  }
}

const provider = new ManyActions();
const store = new KeybindingsStore(provider);
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
createRoot(root).render(
  <UiProvider container={root}>
    <KeybindingsPage store={store} strings={strings} />
  </UiProvider>,
);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".keys-row"));
window.benchChangeOne = async (index) => {
  const binding = provider.table[index]!;
  provider.table[index] = { ...binding, when: binding.when === "editorFocus" ? "terminalFocus" : "editorFocus" };
  await store.reload();
};
void store.reload().then(() => {
  window.benchReady = true;
});
