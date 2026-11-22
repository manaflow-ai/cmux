// l10n-allow-file: bench fixture text, not shipped UI.
// The real Plain English view over N hunks (`#n=10000`: N / 10 files of 10 hunks, each 1 to 7 changed
// lines), for bench/plain-english-visible-only.bench.ts: a stand-in host whose sentences the bench
// answers one at a time. `benchRowRenders` counts the rows that rendered since its last mark, read
// from each mounted row's fiber (test/support/mountedRowRenders.ts), so the view carries no counter.
import "../../src/pages/shared/desktop.css";
import "../../src/styles.css";
import { parsePatchFiles } from "@pierre/diffs";
import { createRoot } from "react-dom/client";
import { PlainEnglishView, type PlainEnglishFile } from "../../src/diff-viewer/PlainEnglishView";
import { SummaryStore, type SummaryFileDiff } from "../../src/diff-viewer/hunkSummaries";
import { diffViewerLabelsFor, type DiffViewerLabelResolver } from "../../src/labels";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Answers the oldest ask still open; false when none is. */
    benchAnswerOne(): boolean;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const HUNKS = 10;

function files(count: number): PlainEnglishFile[] {
  return Array.from({ length: count }, (_, f) => {
    let patch = `diff --git a/src/mod${f % 37}/file${f}.ts b/src/mod${f % 37}/file${f}.ts\n--- a/src/mod${f % 37}/file${f}.ts\n+++ b/src/mod${f % 37}/file${f}.ts\n`;
    for (let h = 0; h < HUNKS; h++) {
      const changed = 1 + ((f * HUNKS + h) % 7);
      const line = 1 + h * 40;
      patch += `@@ -${line},${changed + 2} +${line},${changed + 2} @@\n const before_${h} = ${h};\n`;
      for (let k = 0; k < changed; k++) patch += `-export const v_${f}_${h}_${k} = ${k};\n`;
      for (let k = 0; k < changed; k++) patch += `+export const v_${f}_${h}_${k} = ${k * 2};\n`;
      patch += ` const after_${h} = ${h};\n`;
    }
    return { itemId: `item-${f}`, fileDiff: parsePatchFiles(patch)[0]!.files[0] as unknown as SummaryFileDiff };
  });
}

const open: (() => void)[] = [];
const store = new SummaryStore(
  (path) => new Promise<string>((resolve) => open.push(() => resolve(`Doubles every exported value in ${path}.`))),
);
const labels = diffViewerLabelsFor("en");
const label: DiffViewerLabelResolver = (key) => labels[key];
const root = document.getElementById("root")!;
createRoot(root).render(<PlainEnglishView files={files(Math.ceil(n / HUNKS))} store={store} label={label} />);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".plain-english-hunk"));
window.benchAnswerOne = () => {
  const answer = open.shift();
  answer?.();
  return answer !== undefined;
};
window.benchReady = true;
