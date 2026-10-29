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

const wide: MockTree = Object.fromEntries(
  Array.from({ length: 40 }, (_, index) => [`module-${String(index + 1).padStart(2, "0")}.ts`, null]),
);
const emptyFolder: MockTree = {};
const emptyChild: MockTree = { empty: {} };

type Props = { tree?: MockTree; expand?: string[]; failure?: { code: string; message: string } };

function FilesGallery({ tree = sampleTree, expand = [], failure }: Props) {
  const [store] = useState(() => new FilesStore(new MockFilesProvider(tree, undefined, failure)));
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
    "empty-root": { note: "An empty repository folder explains what to do next.", props: { tree: emptyFolder } },
    "empty-child": {
      note: "An expanded folder with no children keeps the tree action clear.",
      props: { tree: emptyChild, expand: ["empty"] },
    },
    folder: { note: "A repository's top level: folders first, then files.", props: {} },
    expanded: {
      note: "src and src/components open, as Right or a click opens them.",
      props: { expand: ["src", "src/components"] },
    },
    long: { note: "Forty files in one folder: the tree scrolls, the header stays.", props: { tree: wide } },
    "not-a-repository": {
      note: "The chat's folder is in no git repository.",
      props: {
        failure: { code: "cmux.files.not_a_repository", message: "/Users/you/notes is not in a git repository." },
      },
    },
  },
});
