// The send button's menu: a right-click, or a long press, on Send lists the ways this draft can go
// (Send, Queue for later, Send in side chat), each with the key that sends it that way from the
// prompt (sendMenuModel.ts). It is the house context menu (ui/ContextMenu), so in the app the host
// draws it natively with the same rows and shortcut text, and Shift-F10 or the context-menu key on
// a focused Send opens it too. Only Send has the menu: Stop has none.
import {
  cloneElement,
  useEffect,
  useRef,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent,
  type ReactElement,
} from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { contextDescription } from "../../../ui/popupDescriptors";
import { experimentArm } from "../../../experiments/experiment";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { SEND_ICONS, SEND_KEYS, SEND_LABELS, type SendChoice } from "./sendMenuModel";
import { sendMenuLook } from "./sendMenuLook.experiment";
import "./sendMenu.css";

/** How long a press on Send is held before the menu opens instead of a send. */
export const LONG_PRESS_MS = 500;

export function SendMenu({
  choices,
  onChoose,
  children,
}: {
  /** The rows, in order (sendMenuChoices); none keeps the slot's ordinary right-click. */
  choices: readonly SendChoice[];
  onChoose(choice: SendChoice): void;
  /** Send itself. It takes the menu's handlers and stays where it was, no wrapper around it. */
  children: ReactElement<SendPress>;
}) {
  const t = useT();
  const look = experimentArm(sendMenuLook);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  // A long press opened the menu: the click that ends that press is not a send.
  const pressed = useRef(false);
  const stopTimer = () => {
    clearTimeout(timer.current);
    timer.current = undefined;
  };
  useEffect(() => stopTimer, []);
  const items: ContextMenuItem[] = choices.map((choice) => {
    const label = t(SEND_LABELS[choice]);
    const { glyphs } = SEND_KEYS[choice];
    return {
      id: choice,
      ariaLabel: label,
      ...(look === "icons" ? { icon: <Icon name={SEND_ICONS[choice]} size={14} /> } : {}),
      label: (
        <>
          <span className="ui-menu-label">{label}</span>
          {look === "caps" ? (
            <span className="ui-menu-shortcut acpmux-send-menu-caps" aria-hidden="true">
              {glyphs.map((glyph) => (
                <kbd key={glyph} className="acpmux-keycap">
                  {glyph}
                </kbd>
              ))}
            </span>
          ) : (
            <span className="ui-menu-shortcut" aria-hidden="true">
              {glyphs.join("")}
            </span>
          )}
        </>
      ),
      onSelect: () => onChoose(choice),
    };
  });
  const model = contextDescription(
    choices.map((choice) => ({
      id: choice,
      label: t(SEND_LABELS[choice]),
      shortcut: SEND_KEYS[choice].glyphs.join(""),
      ...(look === "icons" ? { icon: SEND_ICONS[choice] } : {}),
    })),
  );
  const onPointerDown = (event: PointerEvent<Element>) => {
    pressed.current = false;
    stopTimer();
    if (event.button !== 0 || items.length === 0) return;
    const target = event.target as Element;
    const at = { clientX: event.clientX, clientY: event.clientY };
    timer.current = setTimeout(() => {
      timer.current = undefined;
      if (!target.isConnected) return;
      pressed.current = true;
      // The same path as a right-click at the pointer, so the menu opens where it is held.
      target.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, ...at }));
    }, LONG_PRESS_MS);
  };
  const onClickCapture = (event: ReactMouseEvent<Element>) => {
    const longPress = pressed.current;
    pressed.current = false;
    // A click from the keys (detail 0) never ends a press: Return or Space on Send sends.
    if (!longPress || event.detail === 0) return;
    event.preventDefault();
    event.stopPropagation();
  };
  return (
    // Send keeps its own place in the composer's action slot (Send right before the mic), as
    // before the menu: the menu and the press add handlers to it, no element around it.
    <ContextMenu asChild popupClassName="acpmux-send-menu-popup" items={items} selection="menu" native={{ model }}>
      {cloneElement(children, {
        onPointerDown,
        onPointerUp: stopTimer,
        onPointerLeave: stopTimer,
        onPointerCancel: stopTimer,
        onClickCapture,
      })}
    </ContextMenu>
  );
}

/** The press handlers SendMenu puts on Send. */
type SendPress = {
  onPointerDown?(event: PointerEvent<Element>): void;
  onPointerUp?(): void;
  onPointerLeave?(): void;
  onPointerCancel?(): void;
  onClickCapture?(event: ReactMouseEvent<Element>): void;
};
