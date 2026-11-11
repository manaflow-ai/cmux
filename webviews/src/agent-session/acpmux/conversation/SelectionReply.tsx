// Act on a part of a message: selecting transcript text shows a small bar above the selection's
// end with four actions, always the same four (#40948): Reply (quotes the selection into the
// composer, the right-click menu's Quote in Reply: AgentPaneContextMenu.swift `quote`, App.tsx
// `chat.quoteReply`), Copy (the selected text, through the app's pasteboard), Ask in side chat (a
// side chat forked from this chat as it is now, asked about the quote, as `/side <prompt>` does)
// and Add to chat (the selection as a context chip in the composer, the menu's Attach selection as
// context). Where that spot holds text (the line before, a "Sent to" line over the reply) it takes
// the nearest spot that covers no other text (selectionReplyPlace). It never floats in the margin
// past the column or leaves the visible transcript. Leo, 2026-11-03: "would it make sense to have a
// direct reply button? or would you mostly just re-read your own thing anyways? what makes sense
// here?"
//
// Ask in side chat used to live only in the right-click menu, as Open in Side Chat, which shows
// only on a row of a finished turn the chat can fork from (messageMenu.ts `messageMenuTarget`:
// not while the agent works, and for agents other than Claude and Codex only on the latest turn).
// The bar's never depends on the row: it forks the chat itself (App.tsx), and where the chat
// cannot open a side chat the click says why instead of the row going missing.
//
// The bar shows when a selection ends (pointer or key up), with no fade-in, and goes as soon as
// the selection collapses or leaves the transcript. It never shows for text in the composer (any
// editable field), in a code block (selected to copy) or in a read-only transcript. It does no
// work per token: it reads the DOM only on a selection's end and while it is shown.
//
// How it looks is a trial the theme can carry (`theme.selectionReply`, the gallery's
// agent-pane.selection-reply): `chip` (the default: each action's glyph and label), `icon` (glyphs
// only), `none` (the right-click menu alone) and `row` (a Reply button on every message's action
// row, kept to show why the chip won).
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { Icon } from "../icons/Icon";
import { Copy, Quote } from "./icons";
import { selectionReplyWrap } from "./selectionReplyWrap.experiment";
import {
  quoteInReply,
  runSelectionAction,
  selectionReplyPlace,
  selectionReplyTarget,
  transcriptClip,
  unselectedTextProbe,
  useSelectionReplyLook,
  type SelectionReplyPlace,
  type SelectionReplyTarget,
} from "./selectionReplyModel";

/// A Reply button for a message's action row (`row` look only), its glyph the row's 16 px
/// (MessageActions.tsx ROW_ICON).
export function RowReplyButton({ text }: { text: string }) {
  const t = useT();
  if (useSelectionReplyLook() !== "row" || !text) return null;
  const label = t("message.quoteReply");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-label={label}
      title={label}
      onClick={() => quoteInReply(text)}
    >
      <Quote size={16} />
    </button>
  );
}

/// The bar's actions, in order: what each runs on the selection and its label key.
type SelectionAction = "reply" | "copy" | "askInSideChat" | "addToChat";
const ACTIONS: readonly SelectionAction[] = ["reply", "copy", "askInSideChat", "addToChat"];
const LABELS = {
  reply: "message.quoteReply",
  copy: "message.selectionCopy",
  askInSideChat: "message.selectionAskInSideChat",
  addToChat: "message.selectionAddToChat",
} as const;
function ActionGlyph({ action }: { action: SelectionAction }) {
  if (action === "reply") return <Quote size={14} />;
  if (action === "copy") return <Copy size={14} />;
  return <Icon name={action === "askInSideChat" ? "agent.chat.new" : "composer.attach"} size={14} />;
}

/// The bar over the selection's end. Mounted once per pane (App.tsx), on the document's body.
export function SelectionReplyChip({ doc = document }: { doc?: Document }) {
  const t = useT();
  const current = useSelectionReplyLook();
  const enabled = current === "chip" || current === "icon";
  const [target, setTarget] = useState<SelectionReplyTarget>();
  const shown = useRef(false);
  shown.current = target !== undefined;
  const bar = useRef<HTMLDivElement>(null);
  // Undefined while the bar is measured; null where no spot takes it (it hides).
  const [placed, setPlaced] = useState<SelectionReplyPlace | null>();
  // The bar's width with its labels: a compact bar is narrower, and the next placement (a scroll)
  // must try the full bar first.
  const fullWidth = useRef(0);

  useEffect(() => {
    if (!enabled) {
      setTarget(undefined);
      return;
    }
    const view = doc.defaultView;
    // A selection's end shows the bar: the pointer let go, or a Shift-arrow key came up.
    const ended = () => setTarget(selectionReplyTarget(doc));
    const keyUp = (event: KeyboardEvent) => {
      if (event.shiftKey || event.key === "Shift" || ((event.metaKey || event.ctrlKey) && event.key === "a")) ended();
    };
    // While shown, a collapsed or changed selection hides it now; it never shows mid-drag.
    const changed = () => {
      if (!shown.current) return;
      const next = selectionReplyTarget(doc);
      if (!next) setTarget(undefined);
    };
    const scrolled = () => {
      if (shown.current) setTarget(selectionReplyTarget(doc));
    };
    doc.addEventListener("pointerup", ended);
    doc.addEventListener("keyup", keyUp);
    doc.addEventListener("selectionchange", changed);
    view?.addEventListener("scroll", scrolled, true);
    view?.addEventListener("resize", scrolled);
    return () => {
      doc.removeEventListener("pointerup", ended);
      doc.removeEventListener("keyup", keyUp);
      doc.removeEventListener("selectionchange", changed);
      view?.removeEventListener("scroll", scrolled, true);
      view?.removeEventListener("resize", scrolled);
    };
  }, [doc, enabled]);

  // Where no transcript text is under it (selectionReplyPlace), read once per shown selection.
  useLayoutEffect(() => {
    if (!target) return setPlaced(undefined);
    if (bar.current && bar.current.dataset.compact !== "true") fullWidth.current = bar.current.offsetWidth;
    const height = bar.current?.offsetHeight ?? 0;
    // Compact, the bar is its glyphs alone: one square button each.
    const size = { width: fullWidth.current, height, compact: ACTIONS.length * height };
    const selection = doc.getSelection();
    const range = selection?.rangeCount ? selection.getRangeAt(0) : undefined;
    if (!range) return setPlaced(undefined);
    const clip = transcriptClip(doc, range.endContainer);
    const pane = {
      width: doc.documentElement.clientWidth || doc.defaultView?.innerWidth || 0,
      height: clip.bottom,
      top: clip.top,
    };
    setPlaced(
      selectionReplyPlace(target, size, pane, unselectedTextProbe(doc, range), experimentArm(selectionReplyWrap)) ??
        null,
    );
  }, [doc, target]);

  const run = useCallback(
    (action: SelectionAction) => {
      if (!target) return;
      if (action === "reply") {
        // Clear the transcript selection first: quoting focuses the composer with its caret under
        // the quote, and clearing after would take that caret too. A quote that fails gets its
        // range back.
        const selection = doc.getSelection();
        const range = selection?.rangeCount ? selection.getRangeAt(0) : undefined;
        selection?.removeAllRanges();
        if (!quoteInReply(target.text) && range) selection?.addRange(range);
      } else if (action === "addToChat") {
        // The chip goes into the composer, which takes focus: the transcript selection goes too.
        if (runSelectionAction("addToChat", target.text)) doc.getSelection()?.removeAllRanges();
      } else {
        // Copy and Ask in side chat leave the selection as it was.
        runSelectionAction(action, target.text);
      }
      setTarget(undefined);
    },
    [doc, target],
  );

  if (!enabled || !target) return null;
  // Glyphs alone where the labels would cover someone else's words (selectionReplyPlace step 7).
  const compact = placed?.compact === true;
  const hidden = placed === null;
  const labelled = current === "chip" && !compact;
  return createPortal(
    <div
      ref={bar}
      role="toolbar"
      className="cv-selection-reply"
      data-look={compact ? "icon" : current}
      data-compact={compact ? "true" : undefined}
      data-hidden={hidden ? "true" : undefined}
      aria-hidden={hidden ? true : undefined}
      aria-label={t("message.selectionActions")}
      style={
        placed
          ? { left: placed.left, top: placed.top }
          : { visibility: "hidden", pointerEvents: "none", left: 0, top: 0 }
      }
      // Pressing the bar keeps the selection it acts on.
      onPointerDown={(event) => event.preventDefault()}
      onMouseDown={(event) => event.preventDefault()}
    >
      {ACTIONS.map((action) => {
        const label = t(LABELS[action]);
        return (
          <button
            key={action}
            type="button"
            className="cv-selection-reply__action"
            data-action={action}
            aria-label={label}
            title={labelled ? undefined : label}
            onClick={() => run(action)}
          >
            <ActionGlyph action={action} />
            {labelled && <span>{label}</span>}
          </button>
        );
      })}
    </div>,
    doc.body,
  );
}
