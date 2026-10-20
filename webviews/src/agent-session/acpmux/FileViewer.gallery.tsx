// l10n-allow-file: gallery fixtures (sample paths and file contents), not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { FileViewer, ViewedFile } from "./FileViewer";

const text = "export function greet(name: string) {\n  return `Hello, ${name}`;\n}\n";
const notes = "Check the upload retry behavior.\n";
const file: ViewedFile = {
  path: "/Users/you/src/atlas-web/src/greet.ts",
  text,
  bytes: text.length,
  truncated: false,
};
const props = (value: ViewedFile): ComponentProps<typeof FileViewer> => ({
  file: value,
  onClose: () => undefined,
  onOpenFile: () => undefined,
});

export default componentEntry<ComponentProps<typeof FileViewer>>({
  id: "agent-pane.file-viewer",
  title: "Chat file viewer",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 420,
  widths: { narrow: 320, normal: 560, wide: 860 },
  covers: ["agent-session/acpmux/FileViewer.tsx#FileViewer"],
  load: () => import("./FileViewer").then((module) => module.FileViewer),
  variants: {
    code: { props: props(file) },
    "plain-text": {
      props: props({ ...file, path: "/Users/you/src/atlas-web/notes.txt", text: notes, bytes: notes.length }),
    },
    "long-name": {
      props: props({
        ...file,
        path: "/Users/you/src/atlas-web/src/components/upload-retry-connection-timeout-regression.test.ts",
      }),
    },
    truncated: { props: props({ ...file, bytes: 100_000, truncated: true }) },
  },
});
