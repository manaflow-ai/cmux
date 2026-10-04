// The latency harness's diff host (diff.harness.ts loads it before the page): the real diff viewer
// page (src/pages/diff/main.tsx) runs on an in-page host
// (mock-host.ts) that serves the cmux.diff ops with a fixed delay: branch and working-tree
// sessions over generated patches, a branch list, viewed files, viewer prefs and comments.
// Patches are served from memory at the page's own /__patch/ path.
// As src/diff/dev.ts does: the dev config stubs the shipped `?inline` stylesheet.
import "../../src/styles.css";
import { diffViewerLabelsFor } from "../../src/labels";
import { HostError, installMockHost } from "./mock-host";

const FILES = 240;

function filePatch(name: string, count: number, variant: string): string {
  const lines: string[] = [];
  for (let k = 0; k < count; k += 1) {
    if (k % 9 === 4) {
      lines.push(
        `-export const ${variant}_${k} = old(${k});`,
        `+export const ${variant}_${k} = next(${k}, "${variant}");`,
      );
    } else lines.push(` export const keep_${k} = ${k};`);
  }
  return `diff --git a/${name} b/${name}\nindex 1111111..2222222 100644\n--- a/${name}\n+++ b/${name}\n@@ -1,${count} +1,${count} @@\n${lines.join("\n")}\n`;
}

function patchFor(variant: string): string {
  const parts: string[] = [];
  const count = variant === "unstaged" ? FILES / 2 : FILES;
  for (let index = 0; index < count; index += 1) {
    const dir = `src/area${String(index % 12).padStart(2, "0")}`;
    parts.push(filePatch(`${dir}/file${String(index).padStart(3, "0")}.ts`, 36, variant.replace(/[^a-z]/gi, "")));
  }
  return parts.join("");
}

const REPO = "/Users/dev/repo";
const TOKEN = "latency-token";
const patches = new Map<string, string>();
let revision = 0;
let sessionCount = 0;

function sessionFor(source: { kind: string; repoRoot?: string; baseRef?: string }) {
  revision += 1;
  sessionCount += 1;
  const variant = source.kind === "branch" ? `branch${source.baseRef ?? "main"}` : source.kind;
  const id = `/__patch/${TOKEN}/${revision}.patch`;
  const text = patchFor(variant);
  patches.set(id, text);
  return {
    type: "sessionOpened",
    value: {
      sessionId: `s${sessionCount}`,
      patch: { id, mediaType: "text/x-diff", byteLength: text.length, revision },
      source,
      generatedPaths: [],
    },
  };
}

// The page fetches its patch from the page origin; answer from memory.
const realFetch = window.fetch.bind(window);
window.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.href);
  const text = patches.get(url.pathname);
  if (text !== undefined) return Promise.resolve(new Response(text, { headers: { "Content-Type": "text/x-diff" } }));
  return realFetch(input, init);
}) as typeof fetch;

const viewed = new Map<string, unknown>();
let prefs: Record<string, unknown> = {};

const branchRows = (selected: string | null) => [
  {
    id: "suggested",
    label: "Suggested",
    rows: ["main", "origin/main", "feat-cmux-next"].map((ref) => ({ ref, label: ref, current: ref === selected })),
  },
  {
    id: "local",
    label: "Local branches",
    rows: Array.from({ length: 60 }, (_, index) => ({ ref: `topic-${index}`, label: `topic-${index}` })),
  },
];

installMockHost(
  {
    "cmux.diff.config": () => ({
      payload: {
        title: "Latency harness",
        transport: { kind: "page", endpoint: "", protocolVersion: 1 },
        capabilityToken: TOKEN,
        sessionSource: { kind: "branch", repoRoot: REPO, baseRef: "main" },
        repoRoot: REPO,
        branchBaseRef: "main",
        layout: "split",
        layoutSource: "default",
        labels: diffViewerLabelsFor("en"),
      },
      ops: ["cmux.diff.comments"],
    }),
    "cmux.diff.protocolHandshake": () => ({
      type: "handshake",
      value: { protocolVersion: 1, capabilities: ["sessions", "branches"] },
    }),
    "cmux.diff.sessionOpen": (params: { source: { kind: string; repoRoot?: string; baseRef?: string } }) =>
      sessionFor(params.source),
    "cmux.diff.sessionClose": () => ({ type: "sessionClosed" }),
    "cmux.diff.branchList": (params: { selectedBase: string | null }) => ({
      type: "branches",
      value: { groups: branchRows(params.selectedBase) },
    }),
    "cmux.diff.branchChange": (params: { baseRef: string }) => {
      if (params.baseRef === "refused") throw new HostError("cmux.diff.bad_ref", "no such ref");
      return { type: "navigation", value: { url: location.href } };
    },
    "cmux.diff.comments": (params: { method: string; params: Record<string, unknown> }) => {
      switch (params.method) {
        case "viewedFiles.list":
          return { files: [...viewed.values()] };
        case "viewedFiles.set": {
          const file = params.params.file as { path: string };
          viewed.set(file.path, file);
          return {};
        }
        case "viewedFiles.clear":
          viewed.delete(params.params.path as string);
          return {};
        case "viewerPrefs.get":
          return { preferences: prefs };
        case "viewerPrefs.set":
          prefs = { ...prefs, ...(params.params.preferences as Record<string, unknown>) };
          return {};
        case "comments.list":
          return { comments: [] };
        default:
          throw new HostError("cmux.diff.unsupported", params.method);
      }
    },
  },
  ["cmux.diff.events"],
);
