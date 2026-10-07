// Page hosts: the real page entry (src/pages/markdown/main.tsx, src/pages/diff/main.tsx) on an
// in-page cmuxPage host (test/latency/mock-host.ts, the latency harness's) that answers the page's
// ops from the state's data. The config carries the look the app sends: the Ghostty theme pair
// and the code font (`appearance`), and for markdown the `markdown` settings (font family, size).
import { HostError, installMockHost } from "../../../test/latency/mock-host";
import { diffViewerLabelsFor, diffViewerLanguage } from "../../labels";
import type { DiffFixtureFile, DiffPageVariant, MarkdownPageVariant } from "../format";
import { addPseudoLocales, isPseudo, pseudoText } from "../pseudo";
import type { StageContext } from "./context";

const hash = (text: string) => {
  let value = 5381;
  for (let index = 0; index < text.length; index += 1) value = (value * 33) ^ text.charCodeAt(index);
  return `h${(value >>> 0).toString(16)}`;
};

export async function mountMarkdownPage(state: MarkdownPageVariant, context: StageContext): Promise<void> {
  // The page reads its tables once, as it loads: the pseudo-locales go in first.
  for (const table of [
    (await import("../../pages/markdown/generated/strings.json")).default,
    (await import("../../viewer-empty/generated/strings.json")).default,
  ])
    addPseudoLocales(table as unknown as Record<string, Record<string, string>>);
  const files = new Map<string, { text: string; hash: string }>();
  if (state.text !== null) files.set(state.path, { text: state.text, hash: hash(state.text) });
  for (const [path, text] of Object.entries(state.files ?? {})) files.set(path, { text, hash: hash(text) });
  const settings = { ...state.settings } as Record<string, unknown>;
  if (context.env.font || context.env.size)
    settings.font = {
      ...(settings.font as object | undefined),
      ...(context.env.font && { family: context.env.font }),
      ...(context.env.size && { size: context.env.size }),
    };
  const config = (path: string) => {
    const file = files.get(path);
    if (!file) throw new HostError("cmux.markdown.not_found", path);
    return {
      path,
      text: file.text,
      hash: file.hash,
      readOnly: state.readOnly === true,
      assetBase: "/__gallery/none/",
      libBase: "/__gallery/none/",
      settings,
      themeCSS: state.themeCSS ?? "",
      appearance: context.appearance,
    };
  };
  const dir = state.path.replace(/[^/]*$/, "");
  const host = installMockHost(
    {
      "cmux.markdown.config": () =>
        state.text === null ? { pick: true, appearance: context.appearance } : config(state.path),
      "cmux.markdown.open": (params: { path: string }) => config(params.path),
      "cmux.markdown.read": () => {
        const file = files.get(state.path);
        return file ? { text: file.text, hash: file.hash } : { deleted: true };
      },
      "cmux.markdown.save": (params: { path: string; text: string }) => {
        const next = { text: params.text, hash: hash(params.text) };
        files.set(params.path, next);
        return { hash: next.hash };
      },
      "cmux.markdown.resolveLinks": (params: { paths: string[] }) => ({
        links: Object.fromEntries(
          params.paths.map((path) => {
            const target = path.startsWith("/") ? path : `${dir}${path.replace(/^\.\//, "")}`;
            return [path, { exists: files.has(target), path: target, kind: "markdown" }];
          }),
        ),
      }),
      "cmux.markdown.listFiles": () => ({ entries: [...files.keys()].map((path) => path.slice(dir.length)) }),
      "cmux.markdown.openLink": () => null,
      "cmux.markdown.recents": () => ({
        items: Object.keys(state.files ?? {}).map((path, index) => ({ path, openedAt: Date.now() - index * 3_600_000 })),
      }),
    },
    ["cmux.markdown.changes", "cmux.markdown.look", "cmux.page.command"],
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "markdown";
  root.dataset.cmuxWebviewKind = "markdown";
  await import("../../pages/markdown/main");
}

function filePatch(file: DiffFixtureFile): string {
  const before = file.before === undefined ? [] : file.before.replace(/\n$/, "").split("\n");
  const after = file.after === undefined ? [] : file.after.replace(/\n$/, "").split("\n");
  const head =
    file.before === undefined
      ? `diff --git a/${file.path} b/${file.path}\nnew file mode 100644\n--- /dev/null\n+++ b/${file.path}\n`
      : file.after === undefined
        ? `diff --git a/${file.path} b/${file.path}\ndeleted file mode 100644\n--- a/${file.path}\n+++ /dev/null\n`
        : `diff --git a/${file.path} b/${file.path}\n--- a/${file.path}\n+++ b/${file.path}\n`;
  // One hunk over the whole file: every line kept, removed or added (a line-level LCS).
  const rows: string[] = [];
  const table = Array.from({ length: before.length + 1 }, () => new Array<number>(after.length + 1).fill(0));
  for (let i = before.length - 1; i >= 0; i -= 1)
    for (let j = after.length - 1; j >= 0; j -= 1)
      table[i]![j] = before[i] === after[j] ? table[i + 1]![j + 1]! + 1 : Math.max(table[i + 1]![j]!, table[i]![j + 1]!);
  let i = 0;
  let j = 0;
  while (i < before.length || j < after.length) {
    if (i < before.length && j < after.length && before[i] === after[j]) {
      rows.push(` ${before[i]}`);
      i += 1;
      j += 1;
    } else if (j < after.length && (i >= before.length || table[i]![j + 1]! >= table[i + 1]![j]!)) {
      rows.push(`+${after[j]}`);
      j += 1;
    } else {
      rows.push(`-${before[i]}`);
      i += 1;
    }
  }
  const start = (lines: string[]) => (lines.length ? 1 : 0);
  return `${head}@@ -${start(before)},${before.length} +${start(after)},${after.length} @@\n${rows.join("\n")}\n`;
}

export function diffPatch(state: DiffPageVariant): string {
  return state.patch ?? (state.files ?? []).map(filePatch).join("");
}

export async function mountDiffPage(state: DiffPageVariant, context: StageContext): Promise<void> {
  await import("../../styles.css");
  const repo = state.repoRoot ?? "/Users/you/src/app";
  const token = "gallery";
  const patch = diffPatch(state);
  const patchPath = `/__patch/${token}/1.patch`;
  const realFetch = window.fetch.bind(window);
  window.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.href);
    if (url.pathname === patchPath)
      return Promise.resolve(new Response(patch, { headers: { "Content-Type": "text/x-diff" } }));
    return realFetch(input, init);
  }) as typeof fetch;
  // The app's host sends no labels, so the shipped viewer falls back to its own English and
  // Japanese tables (labels.ts); a dev build asserts every label instead. The gallery sends that
  // same fallback (pseudo-transformed for a pseudo-locale) in the payload's `labels`.
  const fallback = diffViewerLabelsFor(diffViewerLanguage([context.env.locale]));
  const labels = isPseudo(context.env.locale)
    ? Object.fromEntries(
        Object.entries(fallback).map(([key, text]) => [key, pseudoText(text, context.env.locale as "en-XA")]),
      )
    : fallback;
  const source = { kind: "branch", repoRoot: repo, baseRef: state.baseRef ?? "main" };
  const prefs: Record<string, unknown> = {};
  const host = installMockHost(
    {
      "cmux.diff.config": () => ({
        payload: {
          title: state.title ?? "Changes",
          transport: { kind: "page", endpoint: "", protocolVersion: 1 },
          capabilityToken: token,
          sessionSource: source,
          repoRoot: repo,
          branchBaseRef: source.baseRef,
          layout: state.layout ?? "split",
          layoutSource: "default",
          appearance: context.appearance,
          labels,
        },
        ops: ["cmux.diff.comments"],
      }),
      "cmux.diff.protocolHandshake": () => ({
        type: "handshake",
        value: { protocolVersion: 1, capabilities: ["sessions", "branches"] },
      }),
      "cmux.diff.sessionOpen": () => ({
        type: "sessionOpened",
        value: {
          sessionId: "gallery",
          patch: { id: patchPath, mediaType: "text/x-diff", byteLength: patch.length, revision: 1 },
          source,
          generatedPaths: [],
        },
      }),
      "cmux.diff.sessionClose": () => ({ type: "sessionClosed" }),
      "cmux.diff.branchList": () => ({
        type: "branches",
        value: { groups: [{ id: "suggested", label: "Suggested", rows: [{ ref: "main", label: "main", current: true }] }] },
      }),
      "cmux.diff.comments": (params: { method: string; params: Record<string, unknown> }) => {
        if (params.method === "viewedFiles.list") return { files: [] };
        if (params.method === "viewerPrefs.get") return { preferences: prefs };
        if (params.method === "comments.list") return { comments: [] };
        return {};
      },
    },
    ["cmux.diff.events", "cmux.diff.languages"],
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "diff";
  root.dataset.cmuxWebviewKind = "diff";
  await import("../../pages/diff/main");
}
