// l10n-allow-file: gallery fixtures (sample folder names), not shipped UI.
// The Files page (cmux-page://cmux.files/, cx-p4rt): the same FilesPage main.tsx mounts, over the
// mock `cmux.files.*` provider instead of the host bridge.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { FilesPage } from "./FilesPage";
import { MockFilesProvider, sampleTree, type MockTree } from "./mockProvider";
import { FilesStore } from "./store";
import type { RootInfo } from "./types";

const wide: MockTree = Object.fromEntries(
  Array.from({ length: 40 }, (_, index) => [`module-${String(index + 1).padStart(2, "0")}.ts`, null]),
);

/** A home folder of projects in no repository, some of them repositories. */
const projects: MockTree = {
  cmux: { src: { "main.rs": null }, "README.md": null },
  dotfiles: { zshrc: null },
  experiments: {},
  "notes.md": null,
  "todo.txt": null,
};

type Props = { tree?: MockTree; root?: RootInfo; expand?: string[]; failure?: { code: string; message: string } };

function FilesGallery({ tree = sampleTree, root, expand = [], failure }: Props) {
  const [store] = useState(() => new FilesStore(new MockFilesProvider(tree, root, failure)));
  const [strings] = useState(() => createStrings(table));
  const [opened] = useState(expand);
  useEffect(() => {
    void store.start().then(() => opened.forEach((path) => store.expand(path)));
  }, [store, opened]);
  return <FilesPage store={store} strings={strings} />;
}

export default componentEntry<Props>({
  id: "pages.files",
  title: "Files",
  area: "Pages",
  experimental: true,
  height: 560,
  widths: { narrow: 260, normal: 320, wide: 420 },
  covers: ["page:cmux.files", "pages/files/FilesPage.tsx", "ui/Tree.tsx#Tree"],
  load: async () => FilesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    folder: { note: "A repository's top level: folders first, then files.", props: {} },
    expanded: {
      note: "src and src/components open, as Right or a click opens them.",
      props: { expand: ["src", "src/components"] },
    },
    long: { note: "Forty files in one folder: the tree scrolls, the header stays.", props: { tree: wide } },
    "not-a-repository": {
      note: "The chat's folder is in no git repository (~/Projects): it lists from the disk, folders first.",
      props: { tree: projects, root: { folder: "/Users/you/Projects", name: "Projects" }, expand: ["cmux"] },
    },
    unavailable: {
      note: "The listing failed (a folder that can't be read).",
      props: {
        failure: {
          code: "cmux.files.unavailable",
          message: "The files could not be listed. Choose Refresh from the right-click menu to try again.",
        },
      },
    },
  },
});
