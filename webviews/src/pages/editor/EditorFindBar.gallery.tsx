import { useMemo } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { EditorFind, type FindRange, type FindTarget } from "./editorFind";
import { EditorFindBar } from "./EditorFindBar";

type Props = { text: string; query: string };

/** A stand-in editor: the find runs on `text`. */
function fixture(text: string): FindTarget {
  const lines = text.split("\n");
  return {
    findMatches: (query, matchCase) =>
      lines.flatMap((line, i) => {
        const out: FindRange[] = [];
        const hay = matchCase ? line : line.toLowerCase();
        const needle = matchCase ? query : query.toLowerCase();
        for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + needle.length))
          out.push({
            startLineNumber: i + 1,
            startColumn: at + 1,
            endLineNumber: i + 1,
            endColumn: at + 1 + query.length,
          });
        return out;
      }),
    caret: () => ({ lineNumber: 1, column: 1 }),
    selectedText: () => "",
    show: () => undefined,
    focus: () => undefined,
  };
}

function GalleryEditorFindBar({ text, query }: Props) {
  const strings = useMemo(() => createStrings(table), []);
  const find = useMemo(() => {
    const model = new EditorFind();
    model.attach(fixture(text));
    model.show(query);
    return model;
  }, [text, query]);
  return (
    <div className="ed-frame" style={{ height: 160 }}>
      <EditorFindBar find={find} strings={strings} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "editor.find-bar",
  title: "Code editor find bar",
  area: "Code editor",
  height: 180,
  widths: { narrow: 360, normal: 520, wide: 720 },
  styles: () => Promise.all([import("../../ui/findPill.css"), import("./styles.css")]),
  covers: ["pages/editor/EditorFindBar.tsx#EditorFindBar"],
  load: async () => GalleryEditorFindBar,
  variants: {
    find: { props: { text: "alpha beta\nalpha gamma", query: "alpha" } },
    "no-matches": { props: { text: "alpha beta", query: "zeta" } },
  },
});
