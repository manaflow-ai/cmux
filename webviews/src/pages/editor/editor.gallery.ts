// l10n-allow-file: gallery fixtures (sample code), not shipped UI.
import { minutesAgo } from "../../gallery/clock";
import { editorPageEntry } from "../../gallery/format";

const source = `import { createServer } from "node:http";

export function startServer(port = 8080) {
  return createServer((_request, response) => {
    response.end("hello from the gallery");
  }).listen(port);
}
`;

const largeSource = Array.from(
  { length: 80 },
  (_, index) => `export const generatedValue${index + 1} = ${index + 1}; // keeps the large-file note visible\n`,
).join("");

const recents = Array.from({ length: 24 }, (_, index) => ({
  path: `/Users/you/src/atlas-web/src/feature-${String(index + 1).padStart(2, "0")}/component.tsx`,
  name: `component-${String(index + 1).padStart(2, "0")}.tsx`,
  openedAt: minutesAgo(index * 1440),
}));

export default editorPageEntry({
  id: "pages.editor",
  title: "Code editor",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.editor",
    "pages/editor/EditorPage.tsx#EditorPage",
    "viewer-empty/EditorEmptyState.tsx#EditorEmptyState",
  ],
  variants: {
    empty: {
      note: "No file is open: recent files and the file picker are available.",
      recents,
    },
    loading: {
      note: "The editor is waiting for its file host.",
      loading: true,
    },
    normal: {
      note: "A TypeScript file with syntax highlighting and the status bar.",
      path: "/Users/you/src/atlas-web/src/server.ts",
      text: source,
    },
    focused: {
      note: "The editor surface is ready for typing in a focused pane.",
      path: "/Users/you/src/atlas-web/src/server.ts",
      text: source,
    },
    "edited-unsaved": {
      note: "A recovered draft is loaded as an unsaved edit.",
      path: "/Users/you/src/atlas-web/src/server.ts",
      text: source,
      recoveredText: `${source}\n// Draft change not saved yet.\n`,
    },
    conflict: {
      note: "Unsaved work conflicts with a newer file on disk.",
      path: "/Users/you/src/atlas-web/src/server.ts",
      text: source,
      recoveredText: `${source}\n// Local change.\n`,
      conflict: { hash: "disk-revision-2", text: `${source}\n// Changed on disk.\n` },
    },
    "large-file": {
      note: "A file above the configured threshold disables expensive editor features.",
      path: "/Users/you/src/atlas-web/generated/data.ts",
      text: largeSource,
      size: 9 * 1024 * 1024,
      settings: { largeFileThreshold: 1024 },
    },
    "read-only": {
      note: "A file outside the workspace is readable but cannot be saved.",
      path: "/Users/you/shared/reference.ts",
      text: source,
      readOnly: true,
      readOnlyReason: "outside",
    },
    binary: {
      note: "A binary file is opened read-only with its reason shown.",
      path: "/Users/you/src/atlas-web/assets/logo.png",
      text: "PNG\u0000\u0001\u0002\u0003 gallery fixture",
      readOnly: true,
      readOnlyReason: "binary",
    },
    "many-tabs": {
      note: "The empty state has a long recent-file list for a busy workspace.",
      recents,
    },
    "not-found": {
      note: "The host reports that the requested file no longer exists.",
      error: "not-found",
      path: "/Users/you/src/atlas-web/src/missing.ts",
    },
    "permission-error": {
      note: "The host refuses access to the requested file.",
      error: "permission",
      path: "/Users/you/src/atlas-web/private/config.ts",
    },
    "network-error": {
      note: "The editor owner is disconnected and the page offers Retry.",
      error: "network",
      path: "/Users/you/src/atlas-web/src/server.ts",
    },
  },
});
