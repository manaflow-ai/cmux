// The prompt field's box as it draws before its editor is made (MarkdownField.tsx): the scroller,
// the placeholder and the empty root Milkdown mounts into. MarkdownField draws it, and so does
// LazyPromptEditor (composer/LazyPromptEditor.tsx) while the editor's chunk is still on its way, so
// the field has the same box, placeholder and height from the first frame either way. No editor
// code: a page draws it without Milkdown.
import type React from "react";
import { MINIMAL_SCROLLER_ATTRIBUTE } from "../../scrollers";
import { FADE_BAND_PX } from "./markdownFieldModel";

export function MarkdownFieldFrame({
  className,
  placeholder,
  placeholderKey,
  frameRef,
  placeholderRef,
  rootRef,
  onPointerDown,
}: {
  className?: string;
  placeholder?: string;
  placeholderKey?: string;
  frameRef?: React.Ref<HTMLDivElement>;
  placeholderRef?: React.Ref<HTMLSpanElement>;
  rootRef?: React.Ref<HTMLDivElement>;
  onPointerDown?: React.PointerEventHandler<HTMLDivElement>;
}) {
  return (
    <div
      className={`acpmux-md-field ${className ?? ""}`}
      // A long draft's thin scrollbar (scrollers.ts): kept while it overflows, or under the fade
      // shown while it scrolls and while the pointer is near its edge.
      {...{ [MINIMAL_SCROLLER_ATTRIBUTE]: "" }}
      style={{ "--acpmux-md-fade-band": `${FADE_BAND_PX}px` } as React.CSSProperties}
      ref={frameRef}
      onPointerDown={onPointerDown}
    >
      <span
        ref={placeholderRef}
        className={placeholderKey ? "acpmux-md-placeholder has-key" : "acpmux-md-placeholder"}
        aria-hidden="true"
      >
        {placeholderKey ? <span className="acpmux-md-placeholder-text">{placeholder}</span> : placeholder}
        {placeholderKey && <kbd className="acpmux-md-placeholder-key">{placeholderKey}</kbd>}
      </span>
      <div ref={rootRef} className="acpmux-md-root" />
    </div>
  );
}
