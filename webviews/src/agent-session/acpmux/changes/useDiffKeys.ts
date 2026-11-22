// The changes view's own keys: j and k move between files, n and p between changes. They are
// the view's reading keys, like a list's arrows, so they are drawn as they are (DiffKeyHints)
// rather than bound in Settings, and work only while focus is in the view and not in a field.
import { useEffect, type RefObject } from "react";
import { changeStarts, fileSections, READING_LINE, stepTarget } from "./diffNavigation";

/// The row a change step landed on, marked in its diff so the reader sees where n/p stopped.
export const CURRENT_CHANGE = "data-acpmux-current";

const typing = (target: EventTarget | null) =>
  target instanceof Element &&
  (target.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])") !== null ||
    target.getAttribute("role") === "textbox");

export function useDiffKeys(
  panel: RefObject<HTMLElement | null>,
  body: RefObject<HTMLElement | null>,
  /// Shows a file, as picking it in the tree does: selects it and scrolls its header to the top.
  revealFile: (path: string) => void,
  /// The file last picked, in the tree or with j/k.
  selectedFile: () => string | undefined,
) {
  useEffect(() => {
    const node = panel.current;
    if (!node) return;
    let current: HTMLElement | undefined;
    const onKey = (event: KeyboardEvent) => {
      const scroller = body.current;
      if (!scroller || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
      // A field in a shadow root (Pierre's) targets its host here; the composed path has the field.
      if (event.isComposing || typing(event.composedPath()[0] ?? event.target)) return;
      if (!["j", "k", "n", "p"].includes(event.key)) return;
      const step = event.key === "j" || event.key === "n" ? 1 : -1;
      const box = scroller.getBoundingClientRect();
      if (event.key === "j" || event.key === "k") {
        const sections = fileSections(scroller);
        const tops = sections.map((section) => section.getBoundingClientRect().top);
        // Steps go from the picked file while it shows: a file near the end can't scroll to the
        // top, so measuring from the top would pick it again. Otherwise from the top of the view.
        const picked = sections.findIndex((section) => section.dataset.path === selectedFile());
        const shows =
          picked !== -1 && tops[picked]! < box.top + scroller.clientHeight && (tops[picked + 1] ?? Infinity) > box.top;
        const index = shows ? sections[picked + step] && picked + step : stepTarget(tops, box.top, step);
        event.preventDefault();
        if (index !== undefined) revealFile(sections[index]!.dataset.path ?? "");
        return;
      }
      const starts = changeStarts(scroller);
      const line = box.top + scroller.clientHeight * READING_LINE;
      // Steps go from the change the last step marked while it is in view; otherwise (none yet,
      // or the reader scrolled away) the first change in view is the first stop.
      const marked = current?.isConnected ? current.getBoundingClientRect().top : undefined;
      const from =
        marked !== undefined && marked >= box.top && marked <= box.top + scroller.clientHeight
          ? marked
          : step === 1
            ? box.top - 2
            : line;
      const index = stepTarget(
        starts.map((row) => row.getBoundingClientRect().top),
        from,
        step,
      );
      event.preventDefault();
      if (index === undefined) return;
      const target = starts[index]!;
      current?.removeAttribute(CURRENT_CHANGE);
      target.setAttribute(CURRENT_CHANGE, "");
      current = target;
      scroller.scrollTop += target.getBoundingClientRect().top - line;
    };
    node.addEventListener("keydown", onKey);
    return () => {
      node.removeEventListener("keydown", onKey);
      current?.removeAttribute(CURRENT_CHANGE);
    };
  }, [panel, body, revealFile, selectedFile]);
}
