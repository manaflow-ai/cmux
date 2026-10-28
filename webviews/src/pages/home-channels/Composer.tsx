// The message composer, one rounded box: a Markdown format toolbar on top, the agent pane's prompt
// editor (Shift-Return for a new line, Return sends), then a bar with the format toggle (Aa),
// emoji, @ mention, attach and Send. Every control does something real: the formats are Markdown
// marks in the sent text, the emoji and the mention are inserted text, and files (the attach
// button, a drop on the composer or its drop zone, a paste) upload at once with their progress in
// the tray above the field; Send waits until they are stored. There is no voice or scheduled send.
// In an empty composer, Up edits my last message. The text clears only when the owner took the
// message; the owner's event shows it. A right-click in the field opens the composer's own menu
// (POLISH.md right-click contract): Cut, Copy, Paste, Paste as Plain Text, Attach Files… and
// Insert Mention; the edits run in the app (composerEdit.ts).
import { useContext, useEffect, useRef, useState, type RefObject } from "react";
import { pasteIsOnlyFileNames } from "../../agent-session/acpmux/attachments";
import { PromptEditor, type PromptEditorHandle } from "../../agent-session/acpmux/composer/PromptEditor";
import type { MarkdownFormat } from "../../agent-session/acpmux/markdownFormat";
import type { EmojiTable } from "../../icon-picker/emojiData";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Popover } from "../../ui/Popover";
import { Toolbar, ToolbarButton, ToolbarSeparator } from "../../ui/Toolbar";
import type { Strings } from "../shared/i18n";
import { AttachmentTray, type PendingAttachment } from "./AttachmentViews";
import { ComposerEdit, type ComposerEditCommand } from "./composerEdit";
import { QUOTE_EVENT, quoteMarkdown } from "./quoteSelection";
import { MAX_ATTACHMENTS, attachmentClass, attachmentType, refusal, type AttachmentService } from "./attachmentService";
import { Avatar } from "./Avatar";
import { EmojiPicker, loadEmoji } from "./EmojiPicker";
import { HomeIcon, type HomeIconName } from "./icons";
import { useWebSwapHold } from "../shared/useWebSwapHold";
import type { HomeAttachment, HomeParticipant } from "./types";

export interface ComposerProps {
  placeholder: string;
  label: string;
  strings: Strings;
  disabled?: boolean;
  /** Resolves true when the owner took the message; the text and the sent files clear only then. */
  onSend(text: string, attachments?: readonly HomeAttachment[]): Promise<boolean>;
  /** Files upload to this conversation through this service (absent: no attach). */
  attachments?: { service: AttachmentService; conversation: string };
  /** A wider element that also takes dropped files (the conversation column). */
  dropZone?: RefObject<HTMLElement | null>;
  /** The people an @ mention can name (the conversation's participants other than me). */
  people?: readonly HomeParticipant[];
  /** Up in an empty composer: edit my last message. */
  onEditLast?(): void;
  /** The starting text (an edit of an existing message). */
  initialValue?: string;
  /** An inline edit: Cancel and Save replace Send; Escape cancels. */
  onCancel?(): void;
  /** Take the keyboard focus when it opens (an inline edit started from the keyboard). */
  focusOnOpen?: boolean;
  className?: string;
}

const FORMAT_GROUPS: ReadonlyArray<ReadonlyArray<{ format: MarkdownFormat; icon: HomeIconName; key: string }>> = [
  [
    { format: "bold", icon: "bold", key: "format.bold" },
    { format: "italic", icon: "italic", key: "format.italic" },
    { format: "strike", icon: "strike", key: "format.strike" },
  ],
  [{ format: "link", icon: "link", key: "format.link" }],
  [
    { format: "orderedList", icon: "orderedList", key: "format.orderedList" },
    { format: "bulletList", icon: "bulletList", key: "format.bulletList" },
  ],
  [
    { format: "quote", icon: "quote", key: "format.quote" },
    { format: "code", icon: "code", key: "format.code" },
    { format: "codeBlock", icon: "codeBlock", key: "format.codeBlock" },
  ],
];

type Pop = { kind: "emoji" | "mention" | "link"; anchor: Element };

const formatKey = (formats: Set<MarkdownFormat>) => [...formats].sort().join(" ");

export function Composer({
  placeholder,
  label,
  strings,
  disabled,
  onSend,
  people = [],
  onEditLast,
  initialValue = "",
  onCancel,
  focusOnOpen,
  className,
  attachments,
  dropZone,
}: ComposerProps) {
  const { t } = strings;
  const [value, setValue] = useState(initialValue);
  const [showFormats, setShowFormats] = useState(false);
  const [active, setActive] = useState("");
  const [pop, setPop] = useState<Pop | undefined>();
  const [emoji, setEmoji] = useState<EmojiTable | undefined>();
  const [href, setHref] = useState("");
  const editor = useRef<PromptEditorHandle | null>(null);
  const root = useRef<HTMLDivElement | null>(null);
  const focusedOnce = useRef(false);
  /** A control's glyph inside this composer: where its popover opens. */
  const glyph = (selector: string): Element => root.current?.querySelector(selector) ?? document.body;
  const editing = onCancel !== undefined;
  const [files, setFiles] = useState<readonly PendingAttachment[]>([]);
  const [dropping, setDropping] = useState(false);
  const picker = useRef<HTMLInputElement | null>(null);
  const uploads = useRef(new Map<string, AbortController>());
  const nextFile = useRef(1);
  const ready = files.filter((item) => item.part).map((item) => item.part as HomeAttachment);
  const uploading = files.some((item) => !item.part && !item.error);
  // WEB-SWAP: staged files live only in this composer (an upload aborts on unmount), so a web
  // update's reload waits for them to be sent or removed (pages/shared/webSwap.ts).
  useWebSwapHold(uploading ? "home.uploading" : files.length ? "home.attachments" : null);
  const empty = !value.trim() && ready.length === 0;
  const patchFile = (id: string, patch: Partial<PendingAttachment>) =>
    setFiles((current) => current.map((item) => (item.id === id ? { ...item, ...patch } : item)));
  const addFiles = (list: Iterable<File>) => {
    if (!attachments || disabled) return;
    const added: PendingAttachment[] = [];
    for (const file of list) {
      if (files.length + added.length >= MAX_ATTACHMENTS) break;
      const id = `f${nextFile.current++}`;
      const refused = refusal(file);
      const item: PendingAttachment = { id, file, progress: { sent: 0, total: file.size } };
      if (refused) {
        added.push({ ...item, error: t("attach.tooLarge") });
        continue;
      }
      added.push(item);
      // A small local picture of an image while it uploads (a data URL: any page policy).
      if (attachmentClass(attachmentType(file) ?? "") === "image" && file.size <= 8_000_000) {
        const reader = new FileReader();
        reader.onload = () => typeof reader.result === "string" && patchFile(id, { thumb: reader.result });
        reader.readAsDataURL(file);
      }
      const controller = new AbortController();
      uploads.current.set(id, controller);
      attachments.service
        .upload(attachments.conversation, file, (progress) => patchFile(id, { progress }), controller.signal)
        .then(
          (part) => patchFile(id, { part }),
          (error: unknown) => {
            if (!controller.signal.aborted) patchFile(id, { error: uploadError(error, t) });
          },
        )
        .finally(() => uploads.current.delete(id));
    }
    if (added.length) setFiles((current) => [...current, ...added]);
  };
  const removeFile = (id: string) => {
    uploads.current.get(id)?.abort();
    setFiles((current) => current.filter((item) => item.id !== id));
  };
  // Every upload ends with the composer (a conversation switch makes a new one).
  useEffect(() => {
    const live = uploads.current;
    return () => {
      for (const controller of live.values()) controller.abort();
    };
  }, []);
  // The wider drop zone: files dropped anywhere on the conversation column come here.
  const addRef = useRef(addFiles);
  addRef.current = addFiles;
  useEffect(() => {
    const zone = dropZone?.current;
    if (!zone || !attachments) return;
    // A nested drop zone (the thread sheet over the conversation column) takes its own drops.
    const nested = (event: DragEvent) => {
      const owner = (event.target as Element | null)?.closest?.("[data-drop-zone]");
      return owner !== null && owner !== undefined && owner !== zone;
    };
    const over = (event: DragEvent) => {
      if (!event.dataTransfer?.types.includes("Files")) return;
      // Over the nested zone: that composer shows the hint, this one stops.
      if (nested(event)) return setDropping(false);
      event.preventDefault();
      setDropping(true);
    };
    const leave = (event: DragEvent) => {
      if (!zone.contains(event.relatedTarget as Node | null)) setDropping(false);
    };
    const drop = (event: DragEvent) => {
      if (nested(event)) return setDropping(false);
      if (!event.dataTransfer?.files.length) return;
      event.preventDefault();
      setDropping(false);
      addRef.current(event.dataTransfer.files);
    };
    zone.addEventListener("dragover", over);
    zone.addEventListener("dragleave", leave);
    zone.addEventListener("drop", drop);
    return () => {
      zone.removeEventListener("dragover", over);
      zone.removeEventListener("dragleave", leave);
      zone.removeEventListener("drop", drop);
    };
  }, [dropZone, attachments]);
  const refreshFormats = () => {
    const formats = editor.current?.formats();
    if (formats) setActive(formatKey(formats));
  };
  const submit = (markdown: string) => {
    if (disabled || uploading || (!markdown.trim() && ready.length === 0)) return;
    const sending = ready;
    void onSend(markdown, sending.length ? sending : undefined).then((sent) => {
      if (!sent) return;
      setValue((current) => (current === markdown ? "" : current));
      if (sending.length) setFiles((current) => current.filter((item) => !item.part || !sending.includes(item.part)));
    });
  };
  const format = (kind: MarkdownFormat, anchor: Element) => {
    // A new link asks for its address first; an existing one comes off at once.
    if (kind === "link" && !active.split(" ").includes("link")) {
      setHref("");
      setPop({ kind: "link", anchor });
      return;
    }
    editor.current?.format(kind);
    refreshFormats();
  };
  const insert = (text: string) => {
    setPop(undefined);
    editor.current?.focus();
    editor.current?.insertTyped(text);
  };
  /** A popover closed without a pick (Escape, a press outside): typing goes on in the field. */
  const closePop = () => {
    setPop(undefined);
    editor.current?.focus();
  };
  const openEmoji = (anchor: Element) => {
    setPop({ kind: "emoji", anchor });
    loadEmoji().then(setEmoji, () => setPop(undefined));
  };
  // Quote in Reply (quoteSelection.ts): the quote goes ahead of what is typed, and typing goes on after
  // it. A composer that cannot send (offline, a thread I cannot post in) takes none.
  const disabledRef = useRef(disabled);
  disabledRef.current = disabled;
  useEffect(() => {
    const node = root.current;
    if (!node) return;
    const take = (event: Event) => {
      const text = (event as CustomEvent<string>).detail;
      if (!text || disabledRef.current) return;
      setValue((current) => quoteMarkdown(text) + current);
      editor.current?.focus();
    };
    node.addEventListener(QUOTE_EVENT, take);
    return () => node.removeEventListener(QUOTE_EVENT, take);
  }, []);
  // The field's right-click menu. Cut and Copy need a selection in the field, read as it opens.
  const edit = useContext(ComposerEdit);
  const [selected, setSelected] = useState(false);
  const noteSelection = () => {
    const selection = window.getSelection();
    const element = editor.current?.element();
    setSelected(Boolean(selection && !selection.isCollapsed && element?.contains(selection.anchorNode)));
  };
  const runEdit = (command: ComposerEditCommand) => {
    editor.current?.focus();
    edit?.(command);
  };
  const canAttach = Boolean(attachments) && !editing;
  const fieldMenu: ContextMenuItem[] = [
    {
      id: "cut",
      label: t("composer.menu.cut"),
      disabled: !edit || !selected || disabled,
      onSelect: () => runEdit("cut"),
    },
    { id: "copy", label: t("composer.menu.copy"), disabled: !edit || !selected, onSelect: () => runEdit("copy") },
    { id: "paste", label: t("composer.menu.paste"), disabled: !edit || disabled, onSelect: () => runEdit("paste") },
    {
      id: "pasteAsPlainText",
      label: t("composer.menu.pasteAsPlainText"),
      disabled: !edit || disabled,
      onSelect: () => runEdit("pasteAsPlainText"),
    },
    ...(canAttach
      ? [
          {
            id: "attach",
            label: t("composer.menu.attachFiles"),
            separatorBefore: true,
            disabled: disabled || files.length >= MAX_ATTACHMENTS,
            onSelect: () => picker.current?.click(),
          },
        ]
      : []),
    ...(people.length > 0
      ? [
          {
            id: "mention",
            label: t("composer.menu.insertMention"),
            separatorBefore: !canAttach,
            disabled,
            onSelect: () => setPop({ kind: "mention", anchor: glyph('[data-bar="mention"]') }),
          },
        ]
      : []),
  ];
  return (
    <div
      ref={root}
      className={`hc-composer${disabled ? " disabled" : ""}${editing ? " hc-edit" : ""}${dropping ? " dropping" : ""}${className ? ` ${className}` : ""}`}
      onDragOver={(event) => {
        if (!attachments || dropZone || !event.dataTransfer.types.includes("Files")) return;
        event.preventDefault();
        setDropping(true);
      }}
      onDragLeave={(event) => {
        if (!dropZone && !event.currentTarget.contains(event.relatedTarget as Node | null)) setDropping(false);
      }}
      onDrop={(event) => {
        if (!attachments || dropZone || !event.dataTransfer.files.length) return;
        event.preventDefault();
        setDropping(false);
        addFiles(event.dataTransfer.files);
      }}
      onPasteCapture={(event) => {
        // Pasted files (a screenshot, files copied in a file manager) attach; text still pastes as text.
        if (!attachments || event.clipboardData.files.length === 0) return;
        // A file copied in a file manager also carries its name (or path) as text: drop that text.
        if (pasteIsOnlyFileNames(event.clipboardData)) event.preventDefault();
        addFiles(event.clipboardData.files);
      }}
    >
      {dropping && <div className="hc-drop-hint">{t("attach.drop")}</div>}
      <AttachmentTray items={files} strings={strings} onRemove={removeFile} />
      {showFormats && (
        <Toolbar label={t("format.toolbar")} className="hc-format">
          {FORMAT_GROUPS.map((group, index) => (
            <span key={index} className="hc-format-group">
              {index > 0 && <ToolbarSeparator />}
              {group.map((item) => (
                <ToolbarButton
                  key={item.format}
                  label={t(item.key)}
                  className="hc-tool"
                  pressed={active.split(" ").includes(item.format)}
                  disabled={disabled}
                  keepsFocus
                  onPress={() => format(item.format, glyph(`[data-format="${item.format}"]`))}
                >
                  <span data-format={item.format} className="hc-tool-glyph">
                    <HomeIcon name={item.icon} />
                  </span>
                </ToolbarButton>
              ))}
            </span>
          ))}
        </Toolbar>
      )}
      <ContextMenu className="hc-composer-field-menu" items={fieldMenu} selection="menu" onOpen={noteSelection}>
        <PromptEditor
          ref={(handle) => {
            editor.current = handle;
            // Once, on mount: the handle exists before the editor, which applies the focus when ready.
            if (handle && focusOnOpen && !focusedOnce.current) {
              focusedOnce.current = true;
              handle.focus();
            }
          }}
          value={value}
          onChange={(markdown) => {
            setValue(markdown);
            refreshFormats();
          }}
          onCaret={refreshFormats}
          onKeyDown={(event) => {
            if (event.key === "Escape" && onCancel) {
              event.preventDefault();
              onCancel();
            } else if (event.key === "ArrowUp" && onEditLast && !event.shiftKey && editor.current?.value() === "") {
              event.preventDefault();
              onEditLast();
            }
          }}
          onSubmit={(markdown, { cmd }) => (cmd ? undefined : submit(markdown))}
          placeholder={placeholder}
          attributes={{ "aria-label": label }}
          features={{ multiline: true }}
          className="hc-composer-field"
        />
      </ContextMenu>
      <Toolbar label={t("composer.actions")} className="hc-composer-bar">
        <ToolbarButton
          label={t(showFormats ? "format.hide" : "format.show")}
          className="hc-tool hc-tool-format"
          pressed={showFormats}
          keepsFocus
          onPress={() => setShowFormats((shown) => !shown)}
        >
          <HomeIcon name="format" />
        </ToolbarButton>
        <ToolbarButton
          label={t("emoji.title")}
          tooltip={false}
          className="hc-tool"
          disabled={disabled}
          keepsFocus
          onPress={() => openEmoji(glyph('[data-bar="emoji"]'))}
        >
          <span data-bar="emoji" className="hc-tool-glyph">
            <HomeIcon name="emoji" />
          </span>
        </ToolbarButton>
        {attachments && !editing && (
          <ToolbarButton
            label={t("attach.add")}
            tooltip={false}
            className="hc-tool"
            disabled={disabled || files.length >= MAX_ATTACHMENTS}
            onPress={() => picker.current?.click()}
          >
            <HomeIcon name="attach" />
          </ToolbarButton>
        )}
        {attachments && (
          // oxlint-disable-next-line jsx-a11y/control-has-associated-label -- a hidden picker; the labeled attach button opens it
          <input
            ref={picker}
            type="file"
            multiple
            hidden
            aria-label={t("attach.add")}
            onChange={(event) => {
              if (event.target.files) addFiles(event.target.files);
              event.target.value = "";
            }}
          />
        )}
        {people.length > 0 && (
          <ToolbarButton
            label={t("mention.title")}
            tooltip={false}
            className="hc-tool"
            disabled={disabled}
            keepsFocus
            onPress={() => setPop({ kind: "mention", anchor: glyph('[data-bar="mention"]') })}
          >
            <span data-bar="mention" className="hc-tool-glyph">
              <HomeIcon name="mention" />
            </span>
          </ToolbarButton>
        )}
        <span className="hc-composer-spacer" />
        {!empty && !editing && <span className="hc-composer-hint">{t("composer.newlineHint")}</span>}
        {editing ? (
          <>
            <button type="button" className="hc-text-button" onClick={onCancel}>
              {t("edit.cancel")}
            </button>
            <button
              type="button"
              className="hc-text-button primary"
              disabled={empty}
              onClick={() => submit(editor.current?.value() ?? value)}
            >
              {t("edit.save")}
            </button>
          </>
        ) : (
          <ToolbarButton
            label={t("composer.send")}
            tooltip={false}
            className={`hc-send${empty || disabled || uploading ? "" : " ready"}`}
            disabled={empty || disabled || uploading}
            onPress={() => submit(editor.current?.value() ?? value)}
          >
            <HomeIcon name="send" />
          </ToolbarButton>
        )}
      </Toolbar>
      {pop?.kind === "emoji" && (
        <EmojiPicker anchor={pop.anchor} emoji={emoji} strings={strings} onPick={insert} onClose={closePop} />
      )}
      {pop?.kind === "mention" && (
        <Popover
          open
          onOpenChange={(open) => !open && closePop()}
          anchor={pop.anchor}
          side="top"
          label={t("mention.title")}
          className="hc-pick"
          finalFocus={false}
        >
          <ul className="hc-pick-list">
            {people.map((person) => (
              <li key={person.id}>
                <button type="button" className="hc-pick-row" onClick={() => insert(`@${person.name} `)}>
                  <Avatar participant={person} size={20} />
                  <span>{person.name}</span>
                  {person.chief && <span className="hc-tag">{t("chief.badge")}</span>}
                </button>
              </li>
            ))}
          </ul>
        </Popover>
      )}
      {pop?.kind === "link" && (
        <Popover
          open
          onOpenChange={(open) => !open && closePop()}
          anchor={pop.anchor}
          side="top"
          label={t("format.link")}
          className="hc-link"
          finalFocus={false}
        >
          <form
            onSubmit={(event) => {
              event.preventDefault();
              setPop(undefined);
              editor.current?.format("link", href);
              refreshFormats();
            }}
          >
            <input
              className="hc-link-field"
              type="url"
              value={href}
              placeholder={t("link.placeholder")}
              aria-label={t("link.address")}
              onChange={(event) => setHref(event.target.value)}
            />
            <button type="submit" className="hc-text-button primary" disabled={!href.trim()}>
              {t("link.add")}
            </button>
          </form>
        </Popover>
      )}
    </div>
  );
}

function uploadError(error: unknown, t: (key: string) => string): string {
  const code = typeof error === "object" && error && "code" in error ? String((error as { code: unknown }).code) : "";
  if (code === "cmux.page.unavailable") return t("attach.unavailable");
  return t("attach.failed");
}
