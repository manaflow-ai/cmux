// The workspace group editor's card (cx-rcby, the group bubble): a name field that opens focused
// with the name selected, a row of color dots (No color, the palette, a custom color) and the emoji
// or icon button, then the group's actions in sections split by hairlines. The native bubble
// (SidebarGroupEditor.swift) draws the glass behind it and sizes itself to the card; mount.tsx
// feeds it the host's session. Every press goes out through the callbacks; the card edits nothing.
import { useEffect, useRef, useState, type KeyboardEvent, type MouseEvent, type Ref } from "react";
import { SET_ICON_ITEM, type GroupEditorItem, type GroupEditorSession } from "./host";

/**
 * The card's layout. `native` ships (the AppKit bubble's look, one row of dots); `grid` and
 * `plain` are the gallery's alternatives (group-editor.gallery.tsx).
 */
export type GroupEditorLayout = "native" | "grid" | "plain";

export interface GroupEditorCardProps {
  session: GroupEditorSession;
  /**
   * The dot pressed since the session arrived (a palette id), ringed at once before the host's
   * refresh; undefined shows the session's own choice.
   */
  picked?: string;
  layout?: GroupEditorLayout;
  nameRef?: Ref<HTMLInputElement>;
  cardRef?: Ref<HTMLDivElement>;
  onDraft: (name: string) => void;
  onColor: (color: string) => void;
  onCustomColor: () => void;
  onItem: (item: string) => void;
  onClose: () => void;
}

/** The test ids, parallel to the native editor's accessibility identifiers. */
export const GROUP_EDITOR_IDS = {
  name: "cmux.sidebar.groupEditor.name",
  color: (id: string) => `cmux.sidebar.groupEditor.color.${id}`,
  customColor: "cmux.sidebar.groupEditor.customColor",
  icon: "cmux.sidebar.groupEditor.icon",
  action: (id: string) => `cmux.sidebar.groupEditor.action.${id}`,
} as const;

/**
 * Press handling of the native rows and dots: the mouse-down does nothing (the name field keeps the
 * keys and its selection), the mouse-up inside the control that took the mouse-down activates it.
 * A keyboard press (Space or Return on a focused control: a click with no clicks) activates too.
 */
function usePress() {
  const pressed = useRef<EventTarget | null>(null);
  const [reset] = useState(() => () => {
    pressed.current = null;
  });
  return {
    /** On the document, in capture: a new mouse-down forgets the last one. */
    reset,
    props: (onPress: () => void) => ({
      onMouseDown: (event: MouseEvent) => {
        if (event.button !== 0) return;
        event.preventDefault();
        pressed.current = event.currentTarget;
      },
      onMouseUp: (event: MouseEvent) => {
        const inside = pressed.current === event.currentTarget;
        pressed.current = null;
        if (inside && event.button === 0) onPress();
      },
      onClick: (event: MouseEvent) => {
        if (event.detail === 0) onPress();
      },
    }),
  };
}

/**
 * The dots' keys, as a radio group's: Space or Return presses the focused dot; the arrows move to the
 * next one and pick it (a palette dot only: the custom dot opens the color panel, so it takes focus
 * and waits for Space).
 */
function moveInGroup(event: KeyboardEvent<HTMLElement>) {
  const radios = [...event.currentTarget.querySelectorAll<HTMLElement>('[role="radio"]')];
  const at = radios.indexOf(event.target as HTMLElement);
  if (at < 0) return;
  if (event.key === " " || event.key === "Enter") {
    event.preventDefault();
    radios[at]?.click();
    return;
  }
  const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
  if (!step) return;
  event.preventDefault();
  const rtl = getComputedStyle(event.currentTarget).direction === "rtl";
  const horizontal = event.key === "ArrowLeft" || event.key === "ArrowRight";
  const next = radios[(at + (rtl && horizontal ? -step : step) + radios.length) % radios.length];
  next?.focus();
  if (next && next.dataset.testid !== GROUP_EDITOR_IDS.customColor) next.click();
}

function Eyedropper() {
  return (
    <svg
      className="group-editor-glyph"
      width="12"
      height="12"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M10.5 2.5l3 3M9 4l3 3M11 6l-6.5 6.5L2.5 13.5l1-2L10 5" />
    </svg>
  );
}

function Smiley() {
  return (
    <svg
      className="group-editor-glyph"
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
      aria-hidden="true"
    >
      <circle cx="8" cy="8" r="6.25" />
      <path d="M5.5 9.5c.6.9 1.5 1.4 2.5 1.4s1.9-.5 2.5-1.4" />
      <path d="M6 6.25v.5M10 6.25v.5" />
    </svg>
  );
}

function ActionRow({
  item,
  press,
  onPress,
}: {
  item: GroupEditorItem;
  press: ReturnType<typeof usePress>;
  onPress: () => void;
}) {
  return (
    <button
      type="button"
      className="group-editor-row"
      data-testid={GROUP_EDITOR_IDS.action(item.id)}
      id={GROUP_EDITOR_IDS.action(item.id)}
      {...press.props(onPress)}
    >
      {item.icon ? (
        <span
          className="group-editor-row-icon"
          aria-hidden="true"
          style={{ WebkitMaskImage: `url("${item.icon}")`, maskImage: `url("${item.icon}")` }}
        />
      ) : null}
      <span className="group-editor-row-title">{item.title}</span>
      {item.shortcut ? <span className="group-editor-row-trailing">{item.shortcut}</span> : null}
    </button>
  );
}

export function GroupEditorCard({
  session,
  picked,
  layout = "native",
  nameRef,
  cardRef,
  onDraft,
  onColor,
  onCustomColor,
  onItem,
  onClose,
}: GroupEditorCardProps) {
  const press = usePress();
  const { strings } = session;
  // Escape closes from anywhere on the page (a typed name is kept, as the native bubble does), and
  // every mouse-down forgets the control the last one pressed.
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape" || event.isComposing || event.defaultPrevented) return;
      event.preventDefault();
      onClose();
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("mousedown", press.reset, true);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("mousedown", press.reset, true);
    };
  }, [onClose, press.reset]);
  const chosen = (id: string, sessionChosen: boolean) => (picked === undefined ? sessionChosen : picked === id);
  const customChosen = picked === undefined && session.custom.chosen;
  // The keyboard enters the dots on the chosen one, else the first.
  const focusable =
    session.colors.find((color) => chosen(color.id, color.chosen))?.id ??
    (customChosen ? "custom" : session.colors[0]?.id);
  const sections = session.sections.filter((section) => section.length > 0);
  return (
    <div ref={cardRef} className="group-editor" data-layout={layout}>
      <div className="group-editor-field">
        <input
          ref={nameRef}
          className="group-editor-name"
          type="text"
          defaultValue={session.name}
          placeholder={strings.namePlaceholder}
          aria-label={strings.nameLabel}
          data-testid={GROUP_EDITOR_IDS.name}
          id={GROUP_EDITOR_IDS.name}
          spellCheck={false}
          autoComplete="off"
          onInput={(event) => onDraft(event.currentTarget.value)}
          onKeyDown={(event) => {
            // Return commits the name and closes (the host commits the last draft).
            if (event.key !== "Enter" || event.nativeEvent.isComposing) return;
            event.preventDefault();
            onClose();
          }}
        />
      </div>
      <div className="group-editor-dots">
        <div className="group-editor-radios" role="radiogroup" tabIndex={-1} onKeyDown={moveInGroup}>
          {session.colors.map((color) => {
            const on = chosen(color.id, color.chosen);
            return (
              <span
                key={color.id}
                className="group-editor-swatch"
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the ARIA radio pattern on a color dot; an <input type="radio"> would take focus from the name field on press and change the dots' keys.
                role="radio"
                aria-checked={on}
                aria-label={color.label}
                title={color.label}
                tabIndex={color.id === focusable ? 0 : -1}
                data-chosen={on || undefined}
                data-outlined={color.outlined || undefined}
                data-testid={GROUP_EDITOR_IDS.color(color.id)}
                id={GROUP_EDITOR_IDS.color(color.id)}
                {...press.props(() => onColor(color.id))}
              >
                <span className="group-editor-swatch-fill" style={{ background: color.css }} />
              </span>
            );
          })}
          <span
            className="group-editor-swatch group-editor-custom"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the same radio pattern as the palette dots.
            role="radio"
            aria-checked={customChosen}
            aria-label={strings.customColor}
            title={strings.customColor}
            tabIndex={focusable === "custom" ? 0 : -1}
            data-chosen={customChosen || undefined}
            data-outlined={session.custom.css && customChosen ? undefined : true}
            data-testid={GROUP_EDITOR_IDS.customColor}
            id={GROUP_EDITOR_IDS.customColor}
            {...press.props(onCustomColor)}
          >
            {session.custom.css && customChosen ? (
              <span className="group-editor-swatch-fill" style={{ background: session.custom.css }} />
            ) : (
              <span className="group-editor-swatch-fill">
                <Eyedropper />
              </span>
            )}
          </span>
        </div>
        <button
          type="button"
          className="group-editor-icon-button"
          aria-label={strings.emoji}
          title={strings.emoji}
          data-testid={GROUP_EDITOR_IDS.icon}
          id={GROUP_EDITOR_IDS.icon}
          {...press.props(() => onItem(SET_ICON_ITEM))}
        >
          <Smiley />
        </button>
      </div>
      {sections.map((section, index) => (
        <div className="group-editor-section" key={section[0]?.id ?? index}>
          <hr className="group-editor-hairline" />
          {section.map((item) => (
            <ActionRow key={item.id} item={item} press={press} onPress={() => onItem(item.id)} />
          ))}
        </div>
      ))}
    </div>
  );
}
