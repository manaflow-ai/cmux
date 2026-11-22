// l10n-allow-file: bench fixture file names, not shipped UI.
// The real Cloud page over the mock provider (`#n=10000`), for bench/cloud-feed-visible-only.bench.ts:
// a machine with file ops is selected and its Files section lists a folder of N entries. The bench
// can grow one entry and have the page list the folder again. `benchRowRenders` counts the rows that
// rendered since its last mark, read from each mounted row's fiber (test/support/mountedRowRenders.ts).
import { mountCloudPage } from "../../src/pages/cloud/main";
import { MockCloudProvider } from "../../src/pages/cloud/mockProvider";
import { SAMPLE_FS_MACHINES } from "../../src/pages/cloud/mockData";
import { CloudOps, type FsEntry } from "../../src/pages/cloud/ops";
import type { PageClient } from "../../src/pages/shared/pageClient";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Grows one entry near the top and has the page list the folder again. */
    benchChangeOne(index: number): void | Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const FOLDER = "/home/cmux/big";
const entries: FsEntry[] = Array.from({ length: n }, (_, index) => ({
  name: `file-${String(index).padStart(5, "0")}.ts`,
  kind: index % 10 === 0 ? "directory" : "file",
  size: index * 37,
}));

const mock = new MockCloudProvider();
// The mock's own tree, but for the big folder.
const client: PageClient = {
  call: <R,>(op: string, params: unknown) =>
    op === CloudOps.fsList && (params as { path?: string }).path === FOLDER
      ? Promise.resolve({ path: FOLDER, entries: entries.map((entry) => ({ ...entry })) } as R)
      : mock.call<R>(op, params),
  subscribe: (stream, listener) => mock.subscribe(stream, listener),
  handle: (op, handler) => mock.handle(op, handler),
};

const store = mountCloudPage(document.getElementById("bench-root")!, client);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".cloud-file"));
let grown = 0;
window.benchChangeOne = async () => {
  entries[3] = { ...entries[3]!, size: 1_000_000 + ++grown };
  await store.files.open(FOLDER);
};
void (async () => {
  // Once the machines are listed.
  await new Promise<void>((resolve) => {
    const done = () => store.getSnapshot().machines.length > 0 && (stop(), resolve());
    const stop = store.subscribe(() => void done());
    done();
  });
  await store.select(SAMPLE_FS_MACHINES[0]);
  await store.files.open(FOLDER);
  window.benchReady = true;
})();
