// l10n-allow-file: bench fixture file names, not shipped UI.
// The real Files page (ui/Tree) over N open entries (`#n=10000`), for bench/tree-visible-only.bench.ts:
// a stand-in host whose folder holds a closed folder of five files, then ten open folders of N entries
// in all, and lets the bench rename one file or open the closed folder. `benchRowRenders` counts the
// rows that rendered since its last mark, read from each mounted row's fiber
// (test/support/mountedRowRenders.ts), so the tree carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/files/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/files/generated/strings.json";
import { FilesPage } from "../../src/pages/files/FilesPage";
import { MockFilesProvider, type MockTree } from "../../src/pages/files/mockProvider";
import { FilesStore } from "../../src/pages/files/store";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Renames one file of the first open folder and has the page list its folders again. */
    benchChangeOne(index?: number): void | Promise<void>;
    /** Opens the closed folder at the top. */
    benchExpandOne(): Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const FOLDERS = 10;
const folderName = (folder: number) => `d${String(folder).padStart(2, "0")}`;

const tree: MockTree = { "a-closed": Object.fromEntries(Array.from({ length: 5 }, (_, at) => [`c${at}.ts`, null])) };
for (let folder = 0; folder < FOLDERS; folder++)
  tree[folderName(folder)] = Object.fromEntries(
    Array.from({ length: n / FOLDERS - 1 }, (_, at) => [`file-${String(at).padStart(5, "0")}.ts`, null]),
  );

const store = new FilesStore(new MockFilesProvider(tree));
const root = document.getElementById("root")!;
createRoot(root).render(<FilesPage store={store} strings={createStrings(table, ["en"])} />);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll('[role="treeitem"]'));
let renamed = 0;
window.benchChangeOne = async () => {
  const folder = tree[folderName(0)] as MockTree;
  const name = Object.keys(folder)[1]!;
  delete folder[name];
  folder[`${name.replace(/(-renamed-\d+)?\.ts$/, "")}-renamed-${++renamed}.ts`] = null;
  await store.refresh();
};
window.benchExpandOne = async () => {
  store.expand("a-closed");
  await new Promise((resolve) => setTimeout(resolve, 0));
};
void store.start().then(async () => {
  for (let folder = 0; folder < FOLDERS; folder++) store.expand(folderName(folder));
  await store.refresh();
  window.benchReady = true;
});
