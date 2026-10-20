// l10n-allow-file: gallery fixtures (sample paths and file contents), not shipped UI.
import { useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { FilesEntry, FilesSource } from "./FilesView";

type Props = { folder?: string; state?: "empty" | "outside" | "failed" | "truncated" };
const root = "/Users/you/src/atlas-web";
const files: Record<string, string> = {
  "README.md": "# Atlas web\n\nA sample project for the chat file viewer.\n",
  "src/main.ts": "export const greeting = 'Hello from Atlas';\n",
  "src/net/retry.ts": "export const retryLimit = 3;\n",
};
const folders: Record<string, FilesEntry[]> = {
  [root]: [
    { name: "src", kind: "directory" },
    { name: "README.md", kind: "file" },
  ],
  [`${root}/src`]: [
    { name: "net", kind: "directory" },
    { name: "main.ts", kind: "file" },
  ],
  [`${root}/src/net`]: [{ name: "retry.ts", kind: "file" }],
};

export default componentEntry<Props>({
  id: "agent-pane.files-view",
  title: "Chat files",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 420,
  widths: { narrow: 320, normal: 560, wide: 860 },
  covers: ["agent-session/acpmux/FilesView.tsx#FilesView"],
  load: async () => {
    const { FilesView } = await import("./FilesView");
    const { FileViewer } = await import("./FileViewer");
    return function FilesViewGallery({ folder: initialFolder = root, state }: Props) {
      const [folder, setFolder] = useState(initialFolder);
      const [opened, setOpened] = useState<string>();
      const [closed, setClosed] = useState(false);
      const source = useMemo<FilesSource>(
        () => ({
          list: async (path) => {
            if (state === "outside") throw new Error("Not in a git repository");
            if (state === "failed") throw new Error("Folder unavailable");
            return { entries: state === "empty" ? [] : (folders[path] ?? []), truncated: state === "truncated" };
          },
          search: async (query) => ({
            search_root: root,
            results: Object.keys(files)
              .filter((path) => path.toLowerCase().includes(query.toLowerCase()))
              .map((path) => ({ path })),
          }),
        }),
        [state],
      );
      if (closed) return null;
      if (opened) {
        const text = files[opened.slice(root.length + 1)] ?? "";
        return (
          <FileViewer
            file={{ path: opened, text, bytes: text.length, truncated: false }}
            onClose={() => setOpened(undefined)}
            onOpenFile={() => undefined}
          />
        );
      }
      return (
        <FilesView
          root={root}
          folder={folder}
          source={source}
          onFolder={setFolder}
          onOpen={setOpened}
          onClose={() => setClosed(true)}
        />
      );
    };
  },
  variants: {
    root: { props: {} },
    subfolder: { props: { folder: `${root}/src` } },
    search: {
      props: {},
      play: async (ctx) => {
        await ctx.type("retry", { selector: 'input[type="search"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-files-name")?.textContent === "src/net/retry.ts");
      },
    },
    empty: { props: { state: "empty" } },
    "outside-repository": { props: { state: "outside" } },
    failed: { props: { state: "failed" } },
    truncated: { props: { state: "truncated" } },
  },
});
