// The diff toolbar's jump-to-file palette (DiffToolbar.tsx), open, over a diff of N files. Every
// file's name starts with the harness's typed query ("item 0123"), so each key of a typing step keeps
// all N files and ranks them again.
import { useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { JumpToFilePalette } from "../../../src/DiffToolbar";
import type { DiffItem } from "../../../src/diff-stream";
import type { VisibleListCase } from "./case";

function diffItems(n: number): DiffItem[] {
  return Array.from(
    { length: n },
    (_, index) =>
      ({
        id: `file-${index}`,
        fileDiff: { name: `src/part${index % 40}/item 0123 ${String(index).padStart(5, "0")}.ts` },
      }) as DiffItem,
  );
}

const label = (key: string) => key;
/** The file a jump chose, for a behaviour check. */
const onJump = (id: string) => {
  (window as unknown as { __picked?: string }).__picked = id;
};
let changeOne = () => {};

function CaseJumpToFile({ n }: { n: number }) {
  const [items, setItems] = useState(() => diffItems(n));
  changeOne = () =>
    setItems((previous) =>
      previous.map((item, index) =>
        index === 2 ? { ...item, fileDiff: { name: `${item.fileDiff.name.replace(".ts", "")}x.ts` } } : item,
      ),
    );
  return <JumpToFilePalette items={items} label={label as never} onJump={onJump} />;
}

const jumpToFileCase: VisibleListCase = {
  async mount(root, n) {
    flushSync(() => createRoot(root).render(<CaseJumpToFile n={n} />));
    root.querySelector<HTMLButtonElement>("#jump-to-file-button")!.click();
    while (!document.querySelector('.jump-palette [role="option"]'))
      await new Promise((done) => requestAnimationFrame(done));
    const palette = () => document.querySelector<HTMLElement>(".jump-palette")!;
    return {
      rowSelector: '[role="option"]',
      // The palette's rows are plain elements on the base: no component to count there.
      rowComponents: ["JumpToFileRow"],
      scroller: () => palette().querySelector<HTMLElement>(".jump-palette-list")!,
      list: palette,
      filter: () => palette().querySelector<HTMLElement>("input")!,
      changeOne: () => changeOne(),
      resizeTarget: palette,
    };
  },
};
export default jumpToFileCase;
