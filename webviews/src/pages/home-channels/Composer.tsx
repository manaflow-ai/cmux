// The message composer, one rounded box: a Markdown format toolbar on top, the agent pane's prompt
// editor (Shift-Return for a new line, Return sends), then a bar with the format toggle (Aa),
// emoji, @ mention and Send. Every control does something real: the formats are Markdown marks in
// the sent text, the emoji and the mention are inserted text. The Home send op takes text only,
// so there is no attach, voice, video or scheduled send. In an empty composer, Up edits my last
// message. The text clears only when the owner took the message; the owner's event shows it.
import { useRef, useState } from "react";
import { PromptEditor, type PromptEditorHandle } from "../../agent-session/acpmux/composer/PromptEditor";
import type { MarkdownFormat } from "../../agent-session/acpmux/markdownFormat";
import type { EmojiTable } from "../../icon-picker/emojiData";
import { Popover } from "../../ui/Popover";
import { Toolbar, ToolbarButton, ToolbarSeparator } from "../../ui/Toolbar";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { EmojiPicker, loadEmoji } from "./EmojiPicker";
import { HomeIcon, type HomeIconName } from "./icons";
import type { HomeParticipant } from "./types";

export interface ComposerProps {
  placeholder: string;
  label: string;
  strings: Strings;
  disabled?: boolean;
  /** Resolves true when the owner took the message; the text clears only then. */
  onSend(text: string): Promise<boolean>;
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
  const empty = !value.trim();
  const refreshFormats = () => {
    const formats = editor.current?.formats();
    if (formats) setActive(formatKey(formats));
  };
  const submit = (markdown: string) => {
    if (disabled || !markdown.trim()) return;
    void onSend(markdown).then((sent) => {
      if (sent) setValue((current) => (current === markdown ? "" : current));
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
  return (
    <div
      ref={root}
      className={`hc-composer${disabled ? " disabled" : ""}${editing ? " hc-edit" : ""}${className ? ` ${className}` : ""}`}
    >
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
          className="hc-tool"
          disabled={disabled}
          keepsFocus
          onPress={() => openEmoji(glyph('[data-bar="emoji"]'))}
        >
          <span data-bar="emoji" className="hc-tool-glyph">
            <HomeIcon name="emoji" />
          </span>
        </ToolbarButton>
        {people.length > 0 && (
          <ToolbarButton
            label={t("mention.title")}
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
            className={`hc-send${empty || disabled ? "" : " ready"}`}
            disabled={empty || disabled}
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
