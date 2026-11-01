import React, { useCallback, useImperativeHandle, useRef, useState, type RefObject } from "react";
import { type ComposerAttachment, inlineCopyId, inlineTokenIds } from "./attachments";
import { composerCopy, forgetCopy, pastePlan, pastesPlaced, writeComposerCopy } from "./composer/composerCopy";
import { useInlineAttachments } from "./composer/inlineAttachments";
import {
  AttachmentStrip,
  backspacedAttachment,
  type MadeFile,
  type PendingAttachment,
} from "./composer/attachmentIntake";
import { isPasteAsPlainTextKey, usePastedChips } from "./composer/pastedChips";
import { ComposerFoot } from "./ComposerFoot";
import { useComposerSettings } from "./composerSettings";
import { useRowFit } from "./composerRowFit";
import { MarkdownField, type MarkdownFieldHandle, type MarkdownFieldProps } from "./MarkdownField";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { ChromeArea, type HideableChromeItem } from "../../ui/HideableChrome";

/// What keeps its own press inside the composer card (`focusFromCard`): the text, controls, the menus
/// and dialogs the card opens, and attachments.
const CARD_OWN_PRESS =
  '.ProseMirror, button, a[href], input, textarea, select, label, summary, [contenteditable="true"], [role="button"], [role="link"], [role="menuitem"], [role="option"], [role="checkbox"], [role="radio"], [role="switch"], [role="slider"], [role="tab"], [role="textbox"], [role="combobox"], [role="listbox"], [role="menu"], [role="dialog"], .ui-popup, .acpmux-attachment';

/// What a host does to the box from outside it.
export type ComposerBoxHandle = {
  /// Paste as Plain Text is starting (the prompt's menu): its paste goes in as text, never a chip.
  plainPaste(): void;
  place(chips: readonly PendingAttachment[]): void;
  /// Attachments `ids` went with a prompt: gone from the text for good (composer/inlineAttachments.tsx).
  sent(ids: Iterable<string>): void;
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
  /// A loading chip's × and a failed chip's Retry (attachmentIntake.tsx PendingChip).
  onCancelAttachment?(id: string): void;
  onRetryAttachment?(id: string): void;
  /// A cancelled loading chip's node came back (undo): read its file again; false when it can't.
  onReviveAttachment?(id: string): boolean;
  /// Why a staged image's original failed to upload, by chip id (AttachmentStrip).
  originalFailures?: Readonly<Record<string, string>>;
  /// A staged chip dragged along the strip; unset, the box moves it in `attachments` itself.
  onReorderAttachment?(id: string, index: number): void;
  /// Attaches a file as a pasted one is: a paste of text past what a prompt carries goes as one.
  onPasteFile?(file: MadeFile): void;
  /// Attaches files pasted from the pasteboard at the caret, as the intake's own paste does: a copy of
  /// a composer's text and attachments pasted back in its order (composer/composerCopy.ts).
  onPasteFiles?(files: File[]): void;
  /// The prompt's own right-click menu (POLISH.md right-click contract); WebKit's never shows.
  fieldMenu: ContextMenuItem[];
  onFieldMenuOpen?(): void;
  /// Drawn with the prompt, inside its menu (the chat's shell field over the hidden prompt).
  fieldOverlay?: React.ReactNode;
  /// The box's first children: menus anchored to the field (the `/` and `@` lists) and hidden inputs.
  top?: React.ReactNode;
  /// What a press on the card around the text focuses; unset, the prompt.
  onCardPress?(): void;
  /// The button row's leading control (+) and anything before it.
  leading?: React.ReactNode;
  /// The agent's mode, model and effort chips, in the quiet row under the box (ComposerFoot), in
  /// both looks. The model picker owns any inline Fast toggle.
  chips?: React.ReactNode;
  /// What ends the quiet row (the context ring).
  ring?: React.ReactNode;
  /// The one send control (Send or Stop) before the mic, which keeps the right edge (the plain
  /// footer, in both looks); without the plain footer it is last (`trailing`).
  actionsLead?: React.ReactNode;
  /// The mic, which keeps every width (composerRowFit.ts).
  accessory?: React.ReactNode;
  /// The row's last control: Send or Stop.
  trailing?: React.ReactNode;
  /// The hideable controls the row's right-click shows again (composerChrome.tsx).
  chromeItems: readonly HideableChromeItem[];
  /// Drawn in the composer's bottom area, centered: the chat's look dots (LookSwitch.tsx), in the
  /// quiet row's empty middle.
  bottom?: React.ReactNode;
  /// Nothing in the box takes input (inert): a Cloud start is out, and this tab closes once its
  /// chat opens on the machine, so an edit made meanwhile would go with it (App.tsx `cloudStarting`).
  inert?: boolean;
};

/// The one composer box every surface draws (one-composer: the chat pane, New Tab, Quick
/// Composer): the glass card with the attachments, the markdown prompt and the button row (+, the
/// mic and Send), and with the plain footer the quiet row under it with the mode, model and effort
/// and the context ring. Hosts bring what differs through props: what Return sends, the menus they
/// anchor to the field and the controls of their row.
export function ComposerBox({
  field,
  fieldRef,
  handle,
  boxRef,
  attachments,
  pending,
  setAttachments,
  attachmentsRef,
  attachError,
  codex = false,
  onRemoveAttachment,
  onCancelAttachment,
  onRetryAttachment,
  onReviveAttachment,
  originalFailures,
  onReorderAttachment,
  onPasteFile,
  onPasteFiles,
  fieldMenu,
  onFieldMenuOpen,
  fieldOverlay,
  top,
  onCardPress,
  leading,
  chips,
  ring,
  actionsLead,
  accessory,
  trailing,
  chromeItems,
  bottom,
  inert = false,
}: ComposerBoxProps) {
  // Debug Settings' plain footer look (composerSettings.ts plainFooter, composerLocation.css). Both
  // looks lay the buttons out as Claude's (composerLook.ts): +, the prompt, the mic and Send in the
  // box's grid, the mode, model, effort and ring in the quiet row under it.
  const { plainFooter, attachmentView } = useComposerSettings();
  // The footer look can change from Settings while this component stays mounted: the fit key has it,
  // so the live row is measured again before the new form paints.
  const bar = useRef<HTMLDivElement>(null);
  useRowFit(bar, `${plainFooter}`);
  const prompt = useRef<MarkdownFieldHandle>(null);
  const setPrompt = useCallback(
    (next: MarkdownFieldHandle | null) => {
      prompt.current = next;
      fieldRef?.(next);
    },
    [fieldRef],
  );
  const ownAttachments = useRef(attachments);
  if (!attachmentsRef) ownAttachments.current = attachments;
  // A huge paste is a chip; Paste as Plain Text keeps it raw (composer/pastedChips.ts).
  const pastedChips = usePastedChips(attachmentsRef ?? ownAttachments, setAttachments, prompt, onPasteFile);
  const plainPaste = useRef(pastedChips.plainPaste);
  plainPaste.current = pastedChips.plainPaste;
  const inline = useInlineAttachments({
    field: prompt,
    scope: field.selectionKey,
    text: field.value,
    attachments,
    attachmentsRef: attachmentsRef ?? ownAttachments,
    setAttachments,
    pending: pending ?? [],
    cancel: (id) => onCancelAttachment?.(id),
    retry: (id) => onRetryAttachment?.(id),
    revive: (id) => onReviveAttachment?.(id) ?? false,
    expand: (id) => {
      pastedChips.expand(id);
      prompt.current?.removeInline(id);
    },
    placing: () => !fieldOverlay,
    codex,
    ...(originalFailures ? { originalFailures } : {}),
  });
  // A block pasted again opens its chip as a click does, kept for an undo.
  pastedChips.opens.current = inline.expand;
  useImperativeHandle(
    handle,
    () => ({
      plainPaste: () => plainPaste.current(),
      place: (chips) => inline.place(chips, "paste"),
      sent: (ids) => inline.sent(ids),
    }),
    [inline],
  );
  const placed = new Set(inlineTokenIds(field.value, inline.known));
  const { onBeforeInput, onKeyDown } = field;
  // Select All selects the attachments with the text (Leo, 2026-11-01: "i wanna be able to select
  // all in composer which also selects all the attachments as the copy as well"): those placed in
  // the text are in its selection (composer/inlineNode.ts); the strip's show as selected while the
  // whole draft is, and go with its copy, cut and delete.
  const [whole, setWhole] = useState(false);
  const staged = () => (attachmentsRef ?? ownAttachments).current;
  /// The strip's own attachments, those not placed in the text, go with a whole draft cut or deleted.
  const dropStrip = () => {
    for (const chip of staged().filter((each) => !placed.has(each.id))) {
      inline.remove(chip.id);
      onRemoveAttachment(chip.id);
    }
    if (onCancelAttachment) for (const chip of pending ?? []) if (!placed.has(chip.id)) inline.cancel(chip.id);
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
  return (
    <>
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- A pointer convenience only: the prompt inside is the control and takes the keyboard itself. */}
      <div
        ref={boxRef}
        className="ui-glass ui-glass-floats acpmux-composer-box"
        // The compact grid (composerLocation.css): a state attribute, not a :has() on the box.
        data-composer-grid=""
        data-attachment-view={attachmentView}
        inert={inert}
        onMouseDown={focusFromCard}
      >
        {top}
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
          {...(onRetryAttachment ? { onRetry: onRetryAttachment } : {})}
          {...(originalFailures ? { originalFailures } : {})}
          onReorder={onReorderAttachment ?? inline.reorder}
          onExpand={inline.expand}
        />
        {/* The prompt's own right-click menu (POLISH.md right-click contract); WebKit's never shows. */}
        <ContextMenu className="acpmux-composer-field-menu" items={fieldMenu} selection="menu" onOpen={onFieldMenuOpen}>
          {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
          <MarkdownField
            ref={setPrompt}
            {...field}
            onReady={() => {
              inline.ready();
              field.onReady?.();
            }}
            onInlineViews={inline.onInlineViews}
            isInlineAttachment={inline.known}
            onWholeSelection={setWhole}
            onCopy={(copy, cut) => {
              const made = composerCopy(copy.parts, copy.whole, staged());
              // Text alone is the field's own copy: the last copy with attachments is gone from the pasteboard.
              if (!made) {
                forgetCopy();
                return false;
              }
              writeComposerCopy(made);
              if (cut && copy.whole) dropStrip();
              return true;
            }}
            onPasteFirst={(event) => {
              const plan = pastePlan(event.clipboardData, inline.known);
              if (!plan || (!onPasteFiles && plan.some((part) => "file" in part))) return false;
              pastesPlaced.add(event);
              for (const part of plan) {
                if ("text" in part) prompt.current?.insertText(part.text);
                // An attachment the prompt still has comes back as a copy of it; one cut from it, as itself.
                else if ("id" in part)
                  prompt.current?.insertInline([
                    staged().some((each) => each.id === part.id) ? inlineCopyId(part.id) : part.id,
                  ]);
                else onPasteFiles?.([part.file]);
              }
              return true;
            }}
            onChange={(markdown, caret) => {
              inline.edited(markdown);
              field.onChange(markdown, caret);
            }}
            onBeforeInput={(data, state) => {
              // A huge paste is a chip, the prompt as it was (pastedText.ts); a chip's own text going
              // back in is the person's to edit, never the host's (shell mode).
              if (state.paste && !state.composing && pastedChips.take(data)) return true;
              if (pastedChips.expanding.current) return false;
              return onBeforeInput?.(data, state) ?? false;
            }}
            // ui-allow: the prompt field's own editing keys (⌘⇧V's paste stays text), before the host's.
            onKeyDown={(event) => {
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
              // Backspace at the prompt's start takes back the last chip (backspacedAttachment).
              const backspaced = composing
                ? undefined
                : backspacedAttachment(
                    event,
                    prompt.current?.atStart() ?? false,
                    attachments.filter((chip) => attachmentView === "strip" || !placed.has(chip.id)),
                  );
              if (backspaced) {
                event.preventDefault();
                inline.remove(backspaced.id);
                return;
              }
              onKeyDown?.(event);
            }}
          />
          {inline.chips}
          {fieldOverlay}
        </ContextMenu>
        {/* The button row: a right-click here shows a control hidden from its own (composerChrome.tsx). */}
        <ChromeArea className="acpmux-chrome-area" items={chromeItems}>
          {/* The compact box grid for +, the prompt, the mic and Send, with the model group in
              ComposerFoot, in both looks. The granted-permission status gets no slot of its own
              (hq#1957 item 15 compact row): grants live in the permission mode's Access menu. */}
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
      </div>
      <ChromeArea className="acpmux-chrome-area" items={chromeItems}>
        <ComposerFoot ref={bar} plain={plainFooter}>
          {shownChips}
          {ring}
        </ComposerFoot>
      </ChromeArea>
      {/* One stable host for both looks, so a look switched from the dots by keys keeps the same
          radios and focus: they draw over the quiet row's empty middle (composerLook.css). */}
      {bottom && <div className="acpmux-composer-under">{bottom}</div>}
    </>
  );
}
