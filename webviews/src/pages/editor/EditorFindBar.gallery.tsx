import { useMemo } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { EditorFind, type FindRange, type FindTarget } from "./editorFind";
import { EditorFindBar } from "./EditorFindBar";

type Props = { text: string; query: string; replace: boolean };

/** A stand-in editor: the find runs on `text`, replacements rewrite it. */
function fixture(text: string): FindTarget {
  let lines = text.split("\n");
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
    readOnly: () => false,
    replace: (ranges, replacement) => {
      for (const range of [...ranges].reverse()) {
        const line = lines[range.startLineNumber - 1];
        lines[range.startLineNumber - 1] =
          line.slice(0, range.startColumn - 1) + replacement + line.slice(range.endColumn - 1);
      }
      lines = [...lines];
    },
  };
}

function GalleryEditorFindBar({ text, query, replace }: Props) {
  const strings = useMemo(() => createStrings(table), []);
  const find = useMemo(() => {
    const model = new EditorFind();
    model.attach(fixture(text));
    if (replace) model.showReplace(query);
    else model.show(query);
    return model;
  }, [text, query, replace]);
  return (
    <div className="ed-frame" style={{ height: 160 }}>
      <EditorFindBar find={find} strings={strings} />
    </div>
  );
}

const replaceAll: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "All" });
  await ctx.waitFor(() => ctx.find({ selector: ".find-pill__count" }).textContent === "No matches");
};

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
    find: { props: { text: "alpha beta\nalpha gamma", query: "alpha", replace: false } },
    "no-matches": { props: { text: "alpha beta", query: "zeta", replace: false } },
    replace: { props: { text: "old one\nold two", query: "old", replace: true } },
    "replace-all": { props: { text: "old one\nold two", query: "old", replace: true }, play: replaceAll },
  },
});
