// The one cmux dialog (R96), drawn on the overlay page over the window's own glass: the title, the
// asking origin, the lines, the fields and the buttons (CmuxDialogSpec). The native host places the
// page over the dialog's region, fades it in and dims the window; this card lays itself out in the
// middle and tells the host its rect, where the glass goes. Keys follow CmuxDialogKeys (keys.ts).
import { useLayoutEffect, useRef, useState, type KeyboardEvent } from "react";
import { Dialog } from "../../../ui/Dialog";
import { focusAfter, keyAction } from "./keys";
import type { DialogButtonSpec, DialogField, DialogState, DialogValue } from "./types";

export interface OverlayDialogProps {
  dialog: DialogState;
  /** The person changed a field: every value now. */
  onEdit(values: Record<string, DialogValue>): void;
  onPress(button: string, values: Record<string, DialogValue>): void;
  /** The card's rect in the page (CSS px), after each layout. */
  onLayout(card: { x: number; y: number; w: number; h: number }): void;
}

export function OverlayDialog({ dialog, onEdit, onPress, onLayout }: OverlayDialogProps) {
  const card = useRef<HTMLDivElement | null>(null);
  // The card mounts in the dialog's portal, after this component's own commit: effects follow the node.
  const [cardNode, setCardNode] = useState<HTMLDivElement | null>(null);
  // The values the person typed win over the host's until the host sends a new dialog or sets one.
  const [values, setValues] = useState(dialog.values);
  const [shownValues, setShownValues] = useState(dialog.values);
  if (shownValues !== dialog.values) {
    setShownValues(dialog.values);
    setValues(dialog.values);
  }
  // A secure field's text goes to the host only with the press, never on each key.
  const secure = new Set(dialog.fields.flatMap((field) => (field.kind === "text" && field.secure ? [field.id] : [])));
  const edit = (id: string, value: DialogValue) => {
    const next = { ...values, [id]: value };
    setValues(next);
    onEdit(Object.fromEntries(Object.entries(next).filter(([key]) => !secure.has(key))));
  };
  const press = (button: string) => onPress(button, values);

  useLayoutEffect(() => {
    const node = cardNode;
    if (!node) return;
    const report = () => {
      const rect = node.getBoundingClientRect();
      onLayout({ x: rect.left, y: rect.top, w: rect.width, h: rect.height });
    };
    report();
    const observer = new ResizeObserver(report);
    observer.observe(node);
    observer.observe(document.documentElement);
    return () => observer.disconnect();
  }, [cardNode, onLayout]);

  // The buttons on one line, right-aligned, when they fit; else stacked the card's width with the
  // default on top, as a native alert stacks buttons that do not fit (four quit choices, a long locale).
  const [stacked, setStacked] = useState(false);
  useLayoutEffect(() => {
    const row = cardNode?.querySelector<HTMLElement>(".overlay-dialog-buttons");
    if (!row) return;
    // Measured on one line, before the frame is drawn: the attribute is set back from the result.
    delete row.dataset.stacked;
    const overflows = row.scrollWidth > row.clientWidth + 0.5;
    if (overflows) row.dataset.stacked = "";
    setStacked(overflows);
  }, [cardNode, dialog.buttons]);

  // The first text field takes the keyboard, else the card itself: never a button the person did not
  // choose, so a key typed on as the dialog opens presses nothing.
  const initial = useRef<HTMLElement | null>(null);
  const attachCard = (node: HTMLDivElement | null) => {
    card.current = node;
    setCardNode(node);
    initial.current = node?.querySelector<HTMLElement>("input[type=text], input[type=password]") ?? node;
  };

  // A key the host answered asked the focus to move.
  const focusSerial = dialog.focus?.serial ?? 0;
  const focusBackward = dialog.focus?.backward ?? false;
  useLayoutEffect(() => {
    if (focusSerial > 0 && card.current) moveFocus(card.current, focusBackward);
  }, [focusSerial, focusBackward]);

  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.nativeEvent.isComposing) return;
    const action = keyAction(event, dialog.keys);
    if (!action) return;
    event.preventDefault();
    event.stopPropagation();
    if ("press" in action) press(action.press);
    else if (card.current) moveFocus(card.current, action.focus === "previous");
  };

  const safeDefault = dialog.layout === "safeDefault";
  // A safe-default dialog puts its check boxes under the buttons, as a native alert puts its suppression button.
  const trailing: DialogField[] = safeDefault ? dialog.fields.filter((field) => field.kind === "check") : [];
  const leading = dialog.fields.filter((field) => !trailing.includes(field));
  const main = dialog.buttons.filter((button) => !(safeDefault && button.role === "destructive"));
  const quiet = dialog.buttons.filter((button) => safeDefault && button.role === "destructive");

  return (
    // The host answers the window around the card: an outside press or a missed Escape ends nothing here.
    <Dialog
      open
      onOpenChange={() => {}}
      label={dialog.title}
      className="overlay-dialog-popup"
      backdropClassName="overlay-dialog-backdrop"
      initialFocus={initial}
      onKeyDown={onKeyDown}
    >
      <div
        ref={attachCard}
        className="overlay-dialog"
        data-layout={dialog.layout}
        data-identifier={dialog.identifier}
        tabIndex={-1}
      >
        {dialog.icon && <img className="overlay-dialog-icon" src={dialog.icon} alt="" />}
        <h1 className="overlay-dialog-title">{dialog.title}</h1>
        {dialog.from && <p className="overlay-dialog-from">{dialog.from}</p>}
        {dialog.lines.map((line, index) => (
          <p key={index} className="overlay-dialog-line">
            {line}
          </p>
        ))}
        {leading.map((field, index) => (
          <Field key={fieldKey(field, index)} field={field} values={values} title={dialog.title} onEdit={edit} />
        ))}
        <div className="overlay-dialog-buttons" data-stacked={stacked || undefined}>
          {main.map((button) => (
            <Button key={button.id} button={button} onPress={press} />
          ))}
        </div>
        {quiet.length > 0 && (
          <div className="overlay-dialog-quiet">
            {quiet.map((button) => (
              <Button key={button.id} button={button} quiet onPress={press} />
            ))}
          </div>
        )}
        {trailing.map((field, index) => (
          <Field key={fieldKey(field, index)} field={field} values={values} title={dialog.title} onEdit={edit} />
        ))}
      </div>
    </Dialog>
  );
}

function fieldKey(field: DialogField, index: number): string {
  return field.kind === "preview" ? `preview-${index}` : field.id;
}

function Button({
  button,
  quiet = false,
  onPress,
}: {
  button: DialogButtonSpec;
  quiet?: boolean;
  onPress(id: string): void;
}) {
  return (
    <button
      type="button"
      className="overlay-dialog-button"
      data-role={button.role}
      data-quiet={quiet || undefined}
      data-button={button.id}
      aria-keyshortcuts={button.hintLabel}
      onClick={() => onPress(button.id)}
    >
      <span className="overlay-dialog-button-title">{button.title}</span>
      {button.hint && (
        <kbd className="overlay-dialog-keyhint" aria-hidden="true">
          {button.hint}
        </kbd>
      )}
    </button>
  );
}

function Field({
  field,
  values,
  title,
  onEdit,
}: {
  field: DialogField;
  values: Record<string, DialogValue>;
  title: string;
  onEdit(id: string, value: DialogValue): void;
}) {
  switch (field.kind) {
    case "text":
      return (
        <label className="overlay-dialog-field">
          {field.label && <span className="overlay-dialog-caption">{field.label}</span>}
          <input
            type={field.secure ? "password" : "text"}
            data-field={field.id}
            value={String(values[field.id] ?? "")}
            placeholder={field.placeholder}
            aria-label={field.label ?? field.placeholder ?? title}
            spellCheck={false}
            autoComplete="off"
            onChange={(event) => onEdit(field.id, event.currentTarget.value)}
          />
        </label>
      );
    case "choice":
      return (
        <label className="overlay-dialog-field">
          {field.label && <span className="overlay-dialog-caption">{field.label}</span>}
          <select
            data-field={field.id}
            value={String(values[field.id] ?? "")}
            aria-label={field.label ?? title}
            onChange={(event) => onEdit(field.id, event.currentTarget.value)}
          >
            {field.options.map((option) => (
              <option key={option.value} value={option.value} disabled={!option.enabled}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
      );
    case "check":
      return (
        <label className="overlay-dialog-check">
          <input
            type="checkbox"
            aria-label={field.title}
            data-field={field.id}
            checked={values[field.id] === true}
            onChange={(event) => onEdit(field.id, event.currentTarget.checked)}
          />
          <span>{field.title}</span>
        </label>
      );
    case "preview":
      return <pre className="overlay-dialog-preview">{field.text}</pre>;
  }
}

/** The card's controls in the order the person sees them: fields, then buttons left to right, then
 * the quiet row and the trailing check boxes. */
function focusables(card: HTMLElement): HTMLElement[] {
  return [...card.querySelectorAll<HTMLElement>("input, select, button")].filter(
    (node) => !(node as HTMLInputElement).disabled,
  );
}

function moveFocus(card: HTMLElement, backward: boolean) {
  const controls = focusables(card);
  const current = controls.findIndex(
    (node) => node === document.activeElement || node.contains(document.activeElement),
  );
  const next = focusAfter(current, controls.length, backward);
  controls[next]?.focus();
}
