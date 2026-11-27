import React, {
  useCallback,
  useImperativeHandle,
  useInsertionEffect,
  useRef,
  useState,
  type RefObject,
  useLayoutEffect,
} from "react";
import { type ComposerAttachment, type DroppedKind, inlineCopyId } from "./attachments";
import { composerCopy, forgetCopy, pastePlan, pastesPlaced, writeComposerCopy } from "./composer/composerCopy";
import { stagesComposerCopy } from "./composer/composerCopyStage";
import { useInlineAttachments } from "./composer/inlineAttachments";
import { AttachmentStrip } from "./composer/attachmentIntake";
import { attachStripSize } from "./composer/attachStrip.experiment";
import { experimentArm } from "../../experiments/experiment";
import { backspacedAttachment, type MadeFile, type PendingAttachment } from "./composer/attachmentIntakeModel";
import { isPasteAsPlainTextKey, usePastedChips } from "./composer/pastedChips";
import { ComposerFoot } from "./ComposerFoot";
import { useComposerSettings } from "./composerSettings";
import { lookRowInBox } from "./composerLook";
import { useComposerLookWithV2, useComposerV2 } from "./composerV2";
import { useRowFit } from "./composerRowFit";
import { MarkdownField, type MarkdownFieldHandle, type MarkdownFieldProps } from "./MarkdownField";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { ChromeArea, type HideableChromeItem } from "../../ui/HideableChrome";
import { ComposerListAnchor } from "./backdropLayer";
import { remember } from "./composer/pasteMarks";
import { acpmuxPerf } from "./perf";
import { composerProbe } from "./composerProbe";
import { composerChanged } from "./launchInputEcho";
import { holdFlag, setRef } from "./heldFlag";
import { Slot } from "../../slots/Slot";
import { composerCaretSlot } from "../../slots/composerCaret";
import { watchFocusVisible } from "./focusVisibleMark";
import { composerControlsAnchor } from "./composerControlsAnchor.experiment";
import { ComposerCopyStatusLine, useComposerCopyStatus } from "./composer/ComposerCopyStatus";

/// What keeps its own press inside the composer card (`focusFromCard`): the text, controls, the menus
/// and dialogs the card opens, and attachments.
const CARD_OWN_PRESS =
  '.ProseMirror, button, a[href], input, textarea, select, label, summary, [contenteditable="true"], [role="button"], [role="link"], [role="menuitem"], [role="option"], [role="checkbox"], [role="radio"], [role="switch"], [role="slider"], [role="tab"], [role="textbox"], [role="combobox"], [role="listbox"], [role="menu"], [role="dialog"], .ui-popup, .acpmux-attachment';

/// What a host does to the box from outside it.
export type ComposerBoxHandle = {
  /// Paste as Plain Text is starting (the prompt's menu): its paste goes in as text, never a chip.
  plainPaste(): void;
  place(chips: readonly PendingAttachment[], kind?: DroppedKind): void;
  /// Attachments `ids` went with a prompt: gone from the text for good (composer/inlineAttachments.tsx).
  /// The draft's remembered pastes went with it too.
  sent(ids: Iterable<string>): void;
  /// The pastes that went into the draft as text, newest last (composer/pasteMarks.ts).
  pastes(): readonly string[];
  /// Remembers `texts` as pastes in the draft (a prompt put back with its pastes as text).
  rememberPastes(texts: readonly string[]): void;
};

export type ComposerBoxProps = {
  /// The prompt field: its value and the host's own behavior (what Return does, its menus). The box
  /// runs a huge paste (a Pasted text chip, pastedChips.ts) and ⌘⇧V before the host hears them.
  field: Omit<MarkdownFieldProps, "plugins">;
  /// Receives the prompt field's handle.
  fieldRef?: (handle: MarkdownFieldHandle | null) => void;
  handle?: React.Ref<ComposerBoxHandle>;
  /// Receives the glass card's element (New Tab anchors its suggestions to it).
  boxRef?: React.Ref<HTMLDivElement>;
  /// Hears when focus-visible enters or leaves the card (focusVisibleMark.ts): the host marks its own
  /// parts (`data-focused` on the form, the dock's edge) from it, never with a wide `:has()`. Called on
  /// focus changes only, outside React state, so a keystroke renders nothing.
  onFocusVisible?: (focused: boolean) => void;
  /// What the prompt holds besides its text (attachmentIntake.tsx), shown over the prompt.
  attachments: ComposerAttachment[];
  /// Files still being read: a placeholder chip each, after the staged ones (PendingAttachment).
  pending?: readonly PendingAttachment[];
  setAttachments(update: (current: ComposerAttachment[]) => ComposerAttachment[]): void;
  /// The host's copy of `attachments`, written ahead of a render where the host does (a pick
  /// attached at once), so a paste right after it counts it. Unset, the box keeps its own.
  attachmentsRef?: RefObject<ComposerAttachment[]>;
  attachError?: string;
  /// Codex's attachments say they go as files (AttachmentStrip).
  codex?: boolean;
  onRemoveAttachment(id: string): void;
  /// A loading chip's × (attachmentIntake.tsx PendingChip).
  onCancelAttachment?(id: string): void;
  /// A cancelled loading chip's node came back (undo): read its file again; false when it can't.
  onReviveAttachment?(id: string): boolean;
  /// Why a staged image's original failed to upload, by chip id (AttachmentStrip).
  originalFailures?: Readonly<Record<string, string>>;
  /// A staged chip dragged along the strip; unset, the box moves it in `attachments` itself.
  onReorderAttachment?(id: string, index: number): void;
  /// Attaches a file as a pasted one is: a paste of text past what a prompt carries goes as one.
  onPasteFile?(file: MadeFile): void;
  /// A large paste stays text, and one too long for that is refused (`onPasteRefused`), instead of a
  /// chip or a file (a Cloud start's, composer/pastedChips.ts `keepsText`).
  pasteKeepsText?: boolean;
  onPasteRefused?(): void;
  /// Attaches files pasted from the pasteboard at the caret, as the intake's own paste does: a copy of
  /// a composer's text and attachments pasted back in its order (composer/composerCopy.ts).
  onPasteFiles?(files: File[]): void;
  /// The box is about to change the prompt for the person's own paste (a Pasted text chip, a copy
  /// pasted back): the host counts the change as their edit, as it does a key's.
  onPersonEdit?(): void;
  /// The prompt's own right-click menu (POLISH.md right-click contract); WebKit's never shows.
  fieldMenu: ContextMenuItem[];
  onFieldMenuOpen?(): void;
  /// Drawn with the prompt, inside its menu (the chat's shell field over the hidden prompt).
  fieldOverlay?: React.ReactNode;
  /// The vim mode to show (`agentPane.composerVimKeys` on); unset, nothing is drawn.
  vimMode?: "normal" | "insert";
  /// The box's first children: menus anchored to the field (the `/` and `@` lists, which draw out of
  /// the box's glass, backdropLayer.tsx) and hidden inputs.
  top?: React.ReactNode;
  /// What a press on the card around the text focuses; unset, the prompt.
  onCardPress?(): void;
  /// The button row's leading control (+) and anything before it.
  leading?: React.ReactNode;
  /// The agent's mode, model and effort chips, in the quiet row (ComposerFoot): under the box in
  /// Claude's look, inside it under the prompt in Codex's. The model picker owns any inline Fast toggle.
  chips?: React.ReactNode;
  /// What ends the quiet row (the context ring).
  ring?: React.ReactNode;
  /// Drawn centered in the quiet row, out of its flow (the chat's Customize button,
  /// ComposerCustomizer.tsx); the row's fit never counts it.
  footCenter?: React.ReactNode;
  /// The one send control (Send or Stop) before the mic, which keeps the right edge (the plain
  /// footer, in both looks); without the plain footer it is last (`trailing`).
  actionsLead?: React.ReactNode;
  /// The mic, which keeps every width (composerRowFit.ts).
  accessory?: React.ReactNode;
  /// The row's last control: Send or Stop.
  trailing?: React.ReactNode;
  /// The hideable controls the row's right-click shows again (composerChrome.tsx).
  chromeItems: readonly HideableChromeItem[];
};

/// The one composer box every surface draws (one-composer: the chat pane, New Tab, Quick
/// Composer): the glass card with the attachments, the markdown prompt and the button row (+, the
/// mic and Send), and with the plain footer the quiet row under it with the mode, model and effort
/// and the context ring. Hosts bring what differs through props: what Return sends, the menus they
/// anchor to the field and the controls of their row.
/// The handlers the box gives its field, each its own function.
type FieldHandlers = Required<
  Pick<MarkdownFieldProps, "onReady" | "onCopy" | "onPasteFirst" | "onChange" | "onBeforeInput" | "onKeyDown">
>;

/// One function per handler for the field's whole life, each calling the box's latest.
function stableFieldHandlers(latest: RefObject<FieldHandlers | null>): FieldHandlers {
  return {
    onReady: () => latest.current?.onReady(),
    onCopy: (copy, cut, commitCut) => latest.current?.onCopy(copy, cut, commitCut) ?? false,
    onPasteFirst: (event) => latest.current?.onPasteFirst(event) ?? false,
    onChange: (markdown, caret) => latest.current?.onChange(markdown, caret),
    onBeforeInput: (data, state) => latest.current?.onBeforeInput(data, state) ?? false,
    onKeyDown: (event) => latest.current?.onKeyDown(event),
  };
}

export function ComposerBox({
  field,
  fieldRef,
  handle,
  boxRef,
  onFocusVisible,
  attachments,
  pending,
  setAttachments,
  attachmentsRef,
  attachError,
  codex = false,
  onRemoveAttachment,
  onCancelAttachment,
  onReviveAttachment,
  originalFailures,
  onReorderAttachment,
  onPasteFile,
  onPasteFiles,
  pasteKeepsText = false,
  onPasteRefused,
  onPersonEdit,
  fieldMenu,
  onFieldMenuOpen,
  fieldOverlay,
  vimMode,
  top,
  onCardPress,
  leading,
  chips,
  ring,
  footCenter,
  actionsLead,
  accessory,
  trailing,
  chromeItems,
}: ComposerBoxProps) {
  acpmuxPerf.render("composer:box");
  composerProbe.render?.("box");
  // Debug Settings' plain footer look (composerSettings.ts plainFooter, composerLocation.css). Both
  // looks use the same controls and prompt. Codex's gives the prompt its own full-width line,
  // with + and the trailing actions on the lower row (composerLook.css).
  // The mode, model, effort and ring are the quiet row: under the box in Claude's look, inside it
  // under the prompt in Codex's (Leo 2026-10-30: "the bypass/context/model picker stuff should
  // literally be inside the composer box"; 2026-11-02: "switching to the codex view in the middle of
  // an agent chat doesn't do anything right now"). The row moves on a look switch while the prompt
  // stays mounted, so the draft and caret stay.
  const { plainFooter, attachmentView } = useComposerSettings();
  const rowInBox = lookRowInBox(useComposerLookWithV2());
  // The composer refresh (Settings > Advanced > Experiments, composerV2.ts): its arm and whether the draft has
  // words, as attributes composerV2.css reads; both absent while it is off.
  const composerV2 = useComposerV2();
  const value = field.value;
  const hasText = composerV2 !== undefined && /\S/.test(value);
  // The footer look and the row's place can change while this component stays mounted: the fit key
  // has both, so the live row is measured again before the new form paints.
  const bar = useRef<HTMLDivElement>(null);
  useRowFit(bar, `${plainFooter}:${rowInBox}`);
  const prompt = useRef<MarkdownFieldHandle>(null);
  const fieldHandlers = useRef<FieldHandlers | null>(null);
  const [stableHandlers] = useState(() => stableFieldHandlers(fieldHandlers));
  const setPrompt = useCallback(
    (next: MarkdownFieldHandle | null) => {
      prompt.current = next;
      fieldRef?.(next);
    },
    [fieldRef],
  );
  const ownAttachments = useRef(attachments);
  /// Set while a file with no caret of its own is attached (a Pasted text chip with no node, kept as
  /// a file): its intake places it synchronously (attachmentIntake.tsx), so `place` reads this in
  /// the same call and puts it at the start of the prompt, as every attachment goes in the text.
  const atStart = useRef(false);
  // A huge paste is a chip; Paste as Plain Text keeps it raw (composer/pastedChips.ts).
  const keepsTextNow = useRef({
    keeps: pasteKeepsText,
    refused: onPasteRefused,
  });
  const pastedChips = usePastedChips(
    attachmentsRef ?? ownAttachments,
    setAttachments,
    prompt,
    onPasteFile && ((file, inText = true) => holdFlag(atStart, !inText, () => onPasteFile(file))),
    () => keepsTextNow.current.keeps,
    () => keepsTextNow.current.refused?.(),
  );
  const plainPaste = useRef(pastedChips.plainPaste);
  // The latest of each, written as the render commits: every reader is a handler or an effect, and a
  // write during render keeps the box out of the React Compiler (each key then re-creates every child's
  // props).
  useInsertionEffect(() => {
    if (!attachmentsRef) ownAttachments.current = attachments;
    keepsTextNow.current = { keeps: pasteKeepsText, refused: onPasteRefused };
    plainPaste.current = pastedChips.plainPaste;
  });
  const inline = useInlineAttachments({
    field: prompt,
    scope: field.selectionKey,
    text: value,
    attachments,
    attachmentsRef: attachmentsRef ?? ownAttachments,
    setAttachments,
    pending: pending ?? [],
    cancel: (id) => onCancelAttachment?.(id),
    revive: (id) => onReviveAttachment?.(id) ?? false,
    expand: (id) => {
      pastedChips.expand(id);
      prompt.current?.removeInline(id);
    },
    ...(pastedChips.keepAsFile ? { keepFile: pastedChips.keepAsFile } : {}),
    placing: () => !fieldOverlay,
    codex,
    ...(originalFailures ? { originalFailures } : {}),
  });
  // A block pasted again opens its chip as a click does, kept for an undo.
  setRef(pastedChips.opens, inline.expand);
  useImperativeHandle(
    handle,
    () => ({
      plainPaste: () => {
        plainPaste.current();
        prompt.current?.plainPaste();
      },
      place: (chips, kind) => inline.place(chips, kind, atStart.current),
      sent: (ids) => {
        inline.sent(ids);
        pastedChips.pastes.current = [];
      },
      pastes: () => pastedChips.pastes.current,
      rememberPastes: (texts) => {
        for (const text of texts) pastedChips.pastes.current = remember(pastedChips.pastes.current, text);
      },
    }),
    [inline, pastedChips.pastes],
  );
  const placed = inline.inText(value);
  const { onBeforeInput, onKeyDown } = field;
  // Select All selects the attachments with the text (Leo, 2026-11-01: "i wanna be able to select
  // all in composer which also selects all the attachments as the copy as well"): those placed in
  // the text are in its selection (composer/inlineNode.ts); the strip's show as selected while the
  // whole draft is, and go with its copy, cut and delete.
  const [whole, setWhole] = useState(false);
  const [copyStatus, setCopyStatus] = useComposerCopyStatus(field.selectionKey);
  const staged = () => (attachmentsRef ?? ownAttachments).current;
  /// The strip's own attachments, those not placed in the text, go with a whole draft cut or deleted.
  const dropStrip = (selected?: ReadonlySet<string>) => {
    for (const chip of staged().filter((each) => !placed.has(each.id) && (!selected || selected.has(each.id)))) {
      inline.remove(chip.id);
      onRemoveAttachment(chip.id);
    }
    if (onCancelAttachment)
      for (const chip of pending ?? [])
        if (!placed.has(chip.id) && (!selected || selected.has(chip.id))) inline.cancel(chip.id);
  };
  // A press on the card around the text (the field's padding, the gap around the button row, the
  // card's edge) focuses the prompt where its caret was, as in Codex and Claude Code, whose whole
  // input card is the text area. The text keeps its own press (caret, selection), and the card's
  // controls and attachments keep theirs.
  const focusFromCard = (event: React.MouseEvent<HTMLDivElement>) => {
    // A Control-press opens the context menu on macOS.
    if (event.button !== 0 || event.ctrlKey) return;
    const target = event.target as Element;
    // React hands up presses from what the card portals elsewhere (a menu, a dialog, a backdrop).
    if (!event.currentTarget.contains(target) || target.closest(CARD_OWN_PRESS)) return;
    // A long prompt's scrollbar (the field scrolls past eight lines) keeps its drag.
    if (
      target instanceof HTMLElement &&
      target.scrollHeight > target.clientHeight &&
      event.nativeEvent.offsetX >= target.clientWidth
    )
      return;
    event.preventDefault();
    if (onCardPress) onCardPress();
    else prompt.current?.focus();
  };
  const shownChips = chips;
  const quietRow = (
    <ChromeArea className="acpmux-chrome-area" items={chromeItems}>
      <ComposerFoot ref={bar} plain={plainFooter}>
        {shownChips}
        {ring}
        {footCenter}
      </ComposerFoot>
    </ChromeArea>
  );
  // The box the `/` and `@` lists in `top` float above, drawn outside its glass (backdropLayer.tsx).
  const [boxElement, setBoxElement] = useState<HTMLDivElement | null>(null);
  const attachBox = useCallback(
    (node: HTMLDivElement | null) => {
      setBoxElement(node);
      setRef(boxRef, node);
    },
    [boxRef],
  );
  // The card's focus ring reads `data-focused` (composerStates.css), the card's own state, set here
  // as focus moves: a `:has(:focus-visible)` on the card was checked again for every node a keystroke
  // put in the prompt (transcript-motion-model step 7).
  const focusHeard = useRef(onFocusVisible);
  useInsertionEffect(() => {
    focusHeard.current = onFocusVisible;
  });
  useLayoutEffect(() => {
    if (!boxElement) return;
    const stop = watchFocusVisible(boxElement, (focused) => {
      boxElement.toggleAttribute("data-focused", focused);
      focusHeard.current?.(focused);
    });
    return () => {
      stop();
      boxElement.removeAttribute("data-focused");
      focusHeard.current?.(false);
    };
  }, [boxElement]);
  // The field's handlers, read through `fieldHandlers`: the field is memoized
  // (MarkdownField's sameMarkdownFieldProps) and keeps the same six functions across the box's
  // renders. An upload re-renders the box once a percent; new functions each time re-rendered the
  // editor and wrote its attributes again, about a hundred commits a big screenshot's paste spent
  // on the main thread while WebKit drew its chip.
  const handlers: FieldHandlers = {
    onReady: () => {
      inline.ready();
      field.onReady?.();
    },
    onCopy: (copy, cut, commitCut) => {
      const made = composerCopy(copy.parts, copy.whole, staged());
      // Text alone is the field's own copy: the last copy with attachments is gone from the pasteboard.
      if (!made) {
        forgetCopy();
        setCopyStatus(undefined);
        return false;
      }
      setCopyStatus(undefined);
      if (cut && stagesComposerCopy(made)) {
        const selected = new Set([...staged().map((chip) => chip.id), ...(pending ?? []).map((chip) => chip.id)]);
        writeComposerCopy(made, setCopyStatus, () => {
          if (commitCut() && copy.whole) dropStrip(selected);
        });
        return "pending";
      }
      writeComposerCopy(made, setCopyStatus);
      if (cut && copy.whole) dropStrip();
      return true;
    },
    onPasteFirst: (event) => {
      const plan = pastePlan(event.clipboardData, inline.known);
      if (!plan || (!onPasteFiles && plan.some((part) => "file" in part))) return false;
      pastesPlaced.add(event);
      onPersonEdit?.();
      for (const part of plan) {
        if ("text" in part) prompt.current?.insertText(part.text);
        // An attachment the prompt still has comes back as a copy of it; one cut from it, as itself.
        else if ("id" in part)
          prompt.current?.insertInline(
            [staged().some((each) => each.id === part.id) ? inlineCopyId(part.id) : part.id],
            true,
          );
        else onPasteFiles?.([part.file]);
      }
      return true;
    },
    onChange: (markdown, caret) => {
      composerChanged(); // a launch's first typed key drawn (launchInputEcho.ts)
      inline.edited(markdown);
      field.onChange(markdown, caret);
    },
    onBeforeInput: (data, state) => {
      // A huge paste is a chip, the prompt as it was (pastedText.ts); a chip's own text going
      // back in is the person's to edit, never the host's (shell mode).
      if (state.paste && !state.composing && pastedChips.take(data)) {
        onPersonEdit?.();
        return true;
      }
      if (pastedChips.expanding.current) return false;
      return onBeforeInput?.(data, state) ?? false;
    },
    // ui-allow: the prompt field's own editing keys (⌘⇧V's paste stays text), before the host's.
    onKeyDown: (event) => {
      // Every key belongs to the input method while it composes.
      const composing = event.isComposing || event.keyCode === 229;
      if (!composing && isPasteAsPlainTextKey(event)) pastedChips.plainPaste();
      // Delete over the whole draft takes the strip's attachments with its text.
      if (
        !composing &&
        whole &&
        (event.key === "Backspace" || event.key === "Delete") &&
        !event.ctrlKey &&
        !event.altKey
      ) {
        dropStrip();
        onKeyDown?.(event);
        return;
      }
      // Backspace at the prompt's start takes back the last chip outside the text
      // (backspacedAttachment), in the inline view only: the strip's attachments go by their ×.
      const backspaced =
        composing || attachmentView === "strip"
          ? undefined
          : backspacedAttachment(
              event,
              prompt.current?.atStart() ?? false,
              attachments.filter((chip) => !placed.has(chip.id)),
            );
      if (backspaced) {
        event.preventDefault();
        inline.remove(backspaced.id);
        return;
      }
      onKeyDown?.(event);
    },
  };
  useInsertionEffect(() => {
    fieldHandlers.current = handlers;
  });
  return (
    <>
      <ComposerCopyStatusLine status={copyStatus} />
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- A pointer convenience only: the prompt inside is the control and takes the keyboard itself. */}
      <div
        ref={attachBox}
        className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box"
        // The page's glass, at the popups' tokens (composerStates.css, ONE MATERIAL FAMILY), never the App's:
        // the card animates its height and the App's glass trails a report, and the stack's seams are one rim.
        data-page-glass="docked composer: animates its height and joins the stack's rim, which the App's glass cannot follow"
        // The compact grid (composerLocation.css): a state attribute, not a :has() on the box.
        data-composer-grid=""
        data-attachment-view={attachmentView}
        data-attach-size={experimentArm(attachStripSize)}
        data-composer-v2={composerV2}
        data-has-text={hasText ? "true" : undefined}
        // Where +, the mic and Send stand as the prompt grows (composerControlsAnchor.experiment.ts).
        data-controls-anchor={experimentArm(composerControlsAnchor)}
        onMouseDown={focusFromCard}
      >
        <ComposerListAnchor box={boxElement}>{top}</ComposerListAnchor>
        <AttachmentStrip
          attachments={attachmentView === "inline" ? attachments.filter((chip) => !placed.has(chip.id)) : attachments}
          {...(pending
            ? {
                pending: attachmentView === "inline" ? pending.filter((chip) => !placed.has(chip.id)) : pending,
              }
            : {})}
          {...(attachError ? { error: attachError } : {})}
          codex={codex}
          onRemove={(id) => {
            inline.remove(id);
            onRemoveAttachment(id);
          }}
          selected={whole}
          {...(onCancelAttachment ? { onCancel: inline.cancel } : {})}
          {...(originalFailures ? { originalFailures } : {})}
          onReorder={onReorderAttachment ?? inline.reorder}
          onExpand={inline.expand}
          {...(pastedChips.keepAsFile ? { onKeepFile: inline.keepFile } : {})}
        />
        {/* The prompt's own right-click menu (POLISH.md right-click contract); WebKit's never shows. */}
        <ContextMenu className="acpmux-composer-field-menu" items={fieldMenu} selection="menu" onOpen={onFieldMenuOpen}>
          {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
          <MarkdownField
            ref={setPrompt}
            {...field}
            value={value}
            onReady={stableHandlers.onReady}
            onInlineViews={inline.onInlineViews}
            isInlineAttachment={inline.known}
            inlineHidden={attachmentView === "strip"}
            onWholeSelection={setWhole}
            onCopy={stableHandlers.onCopy}
            onPasteFirst={stableHandlers.onPasteFirst}
            onChange={stableHandlers.onChange}
            onBeforeInput={stableHandlers.onBeforeInput}
            onKeyDown={stableHandlers.onKeyDown}
          />
          {inline.chips}
          {fieldOverlay}
          {/* The theme slot `composer.caret` (slots/composerCaret): its default draws nothing, the
              field's own caret as before. */}
          <Slot slot={composerCaretSlot} props={{ empty: !/\S/.test(field.value) }} />
        </ContextMenu>
        {vimMode && (
          <output className="acpmux-vim-mode" data-vim-mode={vimMode} aria-live="off">
            {vimMode === "normal" ? "NORMAL" : "INSERT"}
          </output>
        )}
        {/* The button row: a right-click here shows a control hidden from its own (composerChrome.tsx). */}
        <ChromeArea className="acpmux-chrome-area" items={chromeItems}>
          {/* The box grid for +, the prompt, the mic and Send, with the model group in
              ComposerFoot. The granted-permission status gets no slot of its own
              (hq#1957 item 15 compact row): grants are revoked from the chat menu (header/grantsMenu.ts). */}
          <div
            className="acpmux-composer-bar acpmux-composer-inner"
            data-footer-look={plainFooter ? "plain" : undefined}
          >
            {leading}
            <span className="acpmux-composer-actions">
              {actionsLead}
              {/* The mic stays at every width; the prompt shrinks instead (composerRowFit.ts). */}
              {accessory && (
                <span className="acpmux-fit-mic" data-fit-part="mic" data-fit-forms="full">
                  {accessory}
                </span>
              )}
              {trailing}
            </span>
          </div>
        </ChromeArea>
        {rowInBox && quietRow}
      </div>
      {!rowInBox && quietRow}
    </>
  );
}
