import React, { useCallback, useImperativeHandle, useRef, type RefObject } from "react";
import type { ComposerAttachment } from "./attachments";
import {
  AttachmentStrip,
  backspacedAttachment,
  type MadeFile,
  type PendingAttachment,
} from "./composer/attachmentIntake";
import { reordered } from "./composer/stripReorder";
import { isPasteAsPlainTextKey, usePastedChips } from "./composer/pastedChips";
import { ComposerFoot } from "./ComposerFoot";
import { useComposerSettings } from "./composerSettings";
import { useQuietRow } from "./composerLook";
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
  /// A staged chip dragged along the strip; unset, the box moves it in `attachments` itself.
  onReorderAttachment?(id: string, index: number): void;
  /// Attaches a file as a pasted one is: a paste of text past what a prompt carries goes as one.
  onPasteFile?(file: MadeFile): void;
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
  /// The agent's mode, model and effort chips: in the box's row, or with the plain footer in the
  /// quiet row under it (ComposerFoot). The model picker owns any inline Fast toggle.
  chips?: React.ReactNode;
  /// What ends the quiet row (the context ring); the plain footer draws it there, Codex's look
  /// before the model in the box's row.
  ring?: React.ReactNode;
  /// The actions before Codex's bolt and the mic (steer, and Stop with the plain footer).
  actionsLead?: React.ReactNode;
  /// The mic, which keeps every width (composerRowFit.ts).
  accessory?: React.ReactNode;
  /// The row's last control: Send or Stop.
  trailing?: React.ReactNode;
  /// The hideable controls the row's right-click shows again (composerChrome.tsx).
  chromeItems: readonly HideableChromeItem[];
  /// Drawn in the composer's bottom area, centered: the chat's look dots (LookSwitch.tsx), in the
  /// quiet row's empty middle, or under the box in Codex's look.
  bottom?: React.ReactNode;
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
  onReorderAttachment,
  onPasteFile,
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
}: ComposerBoxProps) {
  // Debug Settings' plain footer look (composerSettings.ts plainFooter, composerLocation.css): the
  // chips as plain text. With Claude's look (composerLook.ts, the default) they sit in the quiet row
  // under the box; Codex's keeps them in the box's own row.
  const { plainFooter } = useComposerSettings();
  const quietRow = useQuietRow();
  // The controls row swaps whole units as it narrows (composerRowFit.ts).
  const bar = useRef<HTMLDivElement>(null);
  useRowFit(bar, quietRow);
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
  useImperativeHandle(handle, () => ({ plainPaste: () => plainPaste.current() }), []);
  const { onBeforeInput, onKeyDown } = field;
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
      <div ref={boxRef} className="ui-glass ui-glass-floats acpmux-composer-box" onMouseDown={focusFromCard}>
        {top}
        <AttachmentStrip
          attachments={attachments}
          {...(pending ? { pending } : {})}
          {...(attachError ? { error: attachError } : {})}
          codex={codex}
          onRemove={onRemoveAttachment}
          {...(onCancelAttachment ? { onCancel: onCancelAttachment } : {})}
          {...(onRetryAttachment ? { onRetry: onRetryAttachment } : {})}
          onReorder={onReorderAttachment ?? ((id, index) => setAttachments((current) => reordered(current, id, index)))}
          onExpand={pastedChips.expand}
        />
        {/* The prompt's own right-click menu (POLISH.md right-click contract); WebKit's never shows. */}
        <ContextMenu className="acpmux-composer-field-menu" items={fieldMenu} selection="menu" onOpen={onFieldMenuOpen}>
          {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
          <MarkdownField
            ref={setPrompt}
            {...field}
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
              // Backspace at the prompt's start takes back the last chip (backspacedAttachment).
              const backspaced = composing
                ? undefined
                : backspacedAttachment(event, prompt.current?.atStart() ?? false, attachments);
              if (backspaced) {
                event.preventDefault();
                setAttachments((current) => current.filter((item) => item.id !== backspaced.id));
                return;
              }
              onKeyDown?.(event);
            }}
          />
          {fieldOverlay}
        </ContextMenu>
        {/* The button row: a right-click here shows a control hidden from its own (composerChrome.tsx). */}
        <ChromeArea className="acpmux-chrome-area" items={chromeItems}>
          {/* Claude Code's split (Leo 2026-10-19), the plain footer's default: the box keeps +, the
              prompt, the mic and Send or Stop; the mode, model and effort sit in a quiet row under
              it (ComposerFoot below). The other look, and Codex's, keep them all in this row. */}
          <div
            ref={quietRow ? undefined : bar}
            className={quietRow ? "acpmux-composer-bar acpmux-composer-inner" : "acpmux-composer-bar"}
            data-footer-look={plainFooter ? "plain" : undefined}
          >
            {leading}
            {/* The granted-permission status gets no slot of its own in this row (hq#1957 item 15
                compact row): grants live in the permission mode's Access menu, one lock. */}
            {!quietRow && shownChips}
            {/* Codex's look: the context ring before the model, where Codex shows its own. */}
            {!quietRow && plainFooter && ring}
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
      {quietRow && (
        <ChromeArea className="acpmux-chrome-area" items={chromeItems}>
          <ComposerFoot ref={bar}>
            {shownChips}
            {ring}
          </ComposerFoot>
        </ChromeArea>
      )}
      {/* One stable host for both looks, so a look switched from the dots by keys keeps the same
          radios and focus: with the quiet row they draw over its empty middle, with Codex's look
          the host is positioned inside the box's dead-space row (composerLook.css). */}
      {bottom && (
        <div className="acpmux-composer-under" data-beside-foot={quietRow ? "" : undefined}>
          {bottom}
        </div>
      )}
    </>
  );
}
