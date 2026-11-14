// l10n-allow-file: gallery fixtures (sample hunks and sentences), not shipped UI.
// Plain English in the diff viewer: the landed design (one row per hunk, its sentence over its
// folded code, cards per file) in each state, and the two designs it was chosen over.
import { parsePatchFiles } from "@pierre/diffs";
import { useMemo } from "react";
import { componentEntry } from "../gallery/format";
import { PlainEnglishView, type PlainEnglishFile } from "./PlainEnglishView";
import { hunkRefs, SummaryStore, type SummaryFileDiff } from "./hunkSummaries";

const LABELS: Record<string, string> = {
  plainEnglish: "Plain English",
  hunkSummaryLoading: "Summarizing…",
  hunkSummaryFailed: "No summary for this change",
  hunkSummaryOpenInDiff: "Open in diff",
  hunkSummaryNote: "Written by an agent from the code. Check the code before you rely on it.",
};
const label = (key: string) => LABELS[key] ?? key;

const PATCH = `diff --git a/src/net/client.ts b/src/net/client.ts
--- a/src/net/client.ts
+++ b/src/net/client.ts
@@ -1,3 +1,5 @@
+import { withRetry } from "./retry";
+
 export function request(url: string) {
-  return fetch(url).then((response) => response.json());
+  return withRetry(() => fetch(url).then((response) => response.json()), 3);
 }
@@ -8,4 +10,4 @@ export function request(url: string) {
-export function getJSON(url: string) {
-  return request(url);
+export function getJSON<T>(url: string): Promise<T> {
+  return request(url) as Promise<T>;
 }
diff --git a/src/net/retry.ts b/src/net/retry.ts
--- /dev/null
+++ b/src/net/retry.ts
@@ -0,0 +1,8 @@
+export async function withRetry<T>(task: () => Promise<T>, attempts = 3): Promise<T> {
+  for (let attempt = 1; ; attempt += 1) {
+    try {
+      return await task();
+    } catch (error) {
+      if (attempt >= attempts) throw error;
+    }
+  }
+}
diff --git a/src/upload/progress.ts b/src/upload/progress.ts
--- a/src/upload/progress.ts
+++ b/src/upload/progress.ts
@@ -12,3 +12,3 @@ export function progress(sent: number, total: number) {
-  return sent / total;
+  return Math.min(1, total === 0 ? 1 : sent / total);
 }
`;

const SENTENCES = [
  "Retries each request up to three times before giving up.",
  "Makes getJSON generic, so callers name the type they expect.",
  "Adds a helper that reruns a failing task until it runs out of attempts.",
  "Keeps upload progress between 0 and 1, including for an empty file.",
];

const FILES: PlainEnglishFile[] = parsePatchFiles(PATCH)[0]!.files.map((fileDiff, index) => ({
  itemId: `item-${index}`,
  fileDiff: fileDiff as unknown as SummaryFileDiff,
}));
const ORDER = FILES.flatMap((file) => hunkRefs(file.itemId, file.fileDiff));
const sentenceFor = (patch: string) => SENTENCES[ORDER.findIndex((ref) => ref.patch === patch)] ?? SENTENCES[0]!;

type Design = "rows" | "annotated" | "prose";
type Props = { design?: Design; state?: "ready" | "loading" | "arriving" | "mixed" };

/** A store that answers as the variant says: at once, never, after a beat, or with one failure. */
function storeFor(state: NonNullable<Props["state"]>): SummaryStore {
  return new SummaryStore(async (_path, patch) => {
    if (state === "loading") return new Promise<string>(() => {});
    if (state === "arriving") await new Promise((resolve) => setTimeout(resolve, 700));
    if (state === "mixed" && patch === ORDER[1]!.patch) throw new Error("signed out");
    if (state === "mixed" && patch === ORDER[3]!.patch) return new Promise<string>(() => {});
    return sentenceFor(patch);
  }, 4);
}

function PlainEnglishStage({ design = "rows", state = "ready" }: Props) {
  const store = useMemo(() => storeFor(state), [state]);
  if (design === "annotated") {
    // Not taken: the sentence as a banner over each hunk inside the code view. The code is still
    // the page: a 40-file change stays 40 files of code to scroll.
    return (
      <div className="plain-english" style={{ position: "static", height: "100%" }}>
        {ORDER.map((ref) => (
          <div key={ref.id} style={{ marginBottom: 12, border: "1px solid var(--cmux-diff-border)", borderRadius: 12 }}>
            <div style={{ padding: "8px 12px", borderBottom: "1px solid var(--cmux-diff-border)" }}>
              {sentenceFor(ref.patch)}
            </div>
            <pre style={{ margin: 0, padding: "8px 12px", fontSize: "var(--cmux-diff-font-size)", overflow: "hidden" }}>
              {ref.patch.split("\n").slice(1).join("\n")}
            </pre>
          </div>
        ))}
      </div>
    );
  }
  if (design === "prose") {
    // Not taken: each file's sentences as one paragraph. It reads best, but no hunk has a handle
    // to open its code or to go back to it in the diff.
    return (
      <div className="plain-english" style={{ position: "static", height: "100%" }}>
        {FILES.map((file) => {
          const refs = hunkRefs(file.itemId, file.fileDiff);
          return (
            <section key={file.itemId} className="plain-english-file">
              <h3 className="plain-english-path">{refs[0]?.path}</h3>
              <p style={{ margin: "0 4px" }}>{refs.map((ref) => sentenceFor(ref.patch)).join(" ")}</p>
            </section>
          );
        })}
      </div>
    );
  }
  return (
    <div id="viewer" style={{ height: "100%", position: "relative" }}>
      <PlainEnglishView files={FILES} store={store} label={label as any} onOpenInDiff={() => {}} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "diff.plain-english",
  title: "Diff: Plain English",
  area: "Pages",
  height: 520,
  widths: { normal: 760, narrow: 420 },
  covers: ["diff-viewer/PlainEnglishView.tsx", "diff-viewer/hunkSummaries.ts"],
  styles: () => import("../styles.css"),
  load: async () => PlainEnglishStage,
  variants: {
    rows: {
      props: { design: "rows", state: "ready" },
      note: "Landed: a card per file, one row per hunk with its sentence and its +/- counts. A click unfolds the code beneath.",
    },
    "rows-loading": {
      props: { design: "rows", state: "loading" },
      note: "First frame: each row holds the hunk's first changed line in the sentence's place, at the sentence's height.",
    },
    "rows-arriving": {
      props: { design: "rows", state: "arriving" },
      note: "Sentences slide in over the preview without moving any row (Reduce Motion: a fade).",
    },
    "rows-mixed": {
      props: { design: "rows", state: "mixed" },
      note: "One hunk could not be summarized and one is still loading; neither changes a row's height.",
    },
    annotated: {
      props: { design: "annotated" },
      note: "Not taken: a sentence banner over each hunk inside the code. The code is still the page, so a long change is no shorter to read.",
    },
    prose: {
      props: { design: "prose" },
      note: "Not taken: each file's sentences run together as a paragraph. It reads well, but no hunk can be opened or found in the diff.",
    },
  },
});
