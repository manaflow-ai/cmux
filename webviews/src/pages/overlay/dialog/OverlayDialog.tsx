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
  /** The card has been on screen a frame: the host fades it in then. */
  onPainted?(): void;
}

/** `node`'s untransformed box in page coordinates (offsets ignore CSS transforms). */
export function layoutBox(node: HTMLElement): { x: number; y: number; w: number; h: number } {
  let x = 0;
  let y = 0;
  for (let at: HTMLElement | null = node; at; at = at.offsetParent as HTMLElement | null) {
    x += at.offsetLeft;
    y += at.offsetTop;
  }
  return { x, y, w: node.offsetWidth, h: node.offsetHeight };
}

export function OverlayDialog({ dialog, onEdit, onPress, onLayout, onPainted }: OverlayDialogProps) {
  const card = useRef<HTMLDivElement | null>(null);
  // The card mounts in the dialog's portal, after this component's own commit: effects follow the node.
  const [cardNode, setCardNode] = useState<HTMLDivElement | null>(null);
  // What the person typed wins over the host's values until the host sends a new dialog or sets a value
  // (a new values serial): a host update that lags the edit (a focus move, a re-show) keeps every field
  // typed, a secure one or not (review 32 of #37296).
  const serial = dialog.valuesSerial ?? 0;
  const [typed, setTyped] = useState<{ id: number; serial: number; values: Record<string, DialogValue> }>({
    id: dialog.id,
    serial,
    values: {},
  });
  const own = typed.id === dialog.id && typed.serial === serial ? typed.values : {};
  if (own !== typed.values) setTyped({ id: dialog.id, serial, values: {} });
  const values = { ...dialog.values, ...own };
  const edit = (id: string, value: DialogValue) => {
    setTyped({ id: dialog.id, serial, values: { ...own, [id]: value } });
    // Every value, a secure field's too: the host answers keys and automation presses with what it
    // has, as it read the native fields before.
    onEdit({ ...values, [id]: value });
  };
  const press = (button: string) => onPress(button, values);

  useLayoutEffect(() => {
    const node = cardNode;
    if (!node) return;
    // The card's layout box, not its drawn rect: the opening scale of the shared dialog's entrance is a
    // transform, which a ResizeObserver never reports ending, so the glass would keep the opening size.
    const report = () => onLayout(layoutBox(node));
    report();
    const observer = new ResizeObserver(report);
    observer.observe(node);
    observer.observe(document.documentElement);
    return () => observer.disconnect();
  }, [cardNode, onLayout]);

  // Two frames after the card mounted, one of them has drawn it: the host waits for this, not the
  // document's first paint, since a pooled page drew an earlier dialog.
  const painted = useRef(onPainted);
  painted.current = onPainted;
  useLayoutEffect(() => {
    if (!cardNode) return;
    let frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => painted.current?.());
    });
    return () => cancelAnimationFrame(frame);
  }, [cardNode]);

  // The buttons on one line, right-aligned, when they fit; else stacked the card's width with the
  // default on top, as a native alert stacks buttons that do not fit (four quit choices, a long locale).
  const [stacked, setStacked] = useState(false);
  useLayoutEffect(() => {
    const row = cardNode?.querySelector<HTMLElement>(".overlay-dialog-buttons");
    if (!row) return;
    // Measured on one line, before the frame is drawn: the attribute is set back from the result. Again
    // when the card or the page resizes (the interface scale, a longer title), so the row fits as it shows.
    const measure = () => {
      delete row.dataset.stacked;
      // The buttons' own widths and gaps: the row is end-aligned, so what overflows it spills past its
      // left edge, which its scrollWidth never counts.
      const buttons = [...row.children].filter((child): child is HTMLElement => child instanceof HTMLElement);
      const gap = Number.parseFloat(getComputedStyle(row).columnGap) || 0;
      // Drawn widths at the row's layout size: the entrance's opening scale shrinks what is drawn, and a
      // ResizeObserver never hears it end, so a row that does not fit would measure as fitting.
      const drawn = row.getBoundingClientRect().width;
      const scale = row.offsetWidth > 0 && drawn > 0 ? drawn / row.offsetWidth : 1;
      const needed =
        buttons.reduce((sum, button) => sum + button.getBoundingClientRect().width, 0) / scale +
        gap * Math.max(0, buttons.length - 1);
      const overflows = needed > row.clientWidth + 0.5;
      if (overflows) row.dataset.stacked = "";
      setStacked(overflows);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(row);
    observer.observe(document.documentElement);
    return () => observer.disconnect();
  }, [cardNode, dialog.buttons]);

  // The first text field takes the keyboard, else the card itself: never a button the person did not
  // choose, so a key typed on as the dialog opens presses nothing.
  const initial = useRef<HTMLElement | null>(null);
  const attachCard = (node: HTMLDivElement | null) => {
    card.current = node;
    setCardNode(node);
    initial.current = node?.querySelector<HTMLElement>("input[type=text], input[type=password]") ?? node;
  };

  // Shown again after its tab was hidden: the focus goes back where the dialog opens, never a button.
  const shown = dialog.shown ?? 1;
  useLayoutEffect(() => {
    if (shown > 1) initial.current?.focus();
  }, [shown]);

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
        // The card takes the keyboard when no text field does (Return, Escape), as an open popover does,
        // and like one it draws no ring around itself: the clear card's ring was a dark second edge around
        // the native glass (Lawrence 2026-11-07, "weird border"). Its buttons keep their rings.
        data-focus-ring="none"
        tabIndex={-1}
      >
        {dialog.icon && <img className="overlay-dialog-icon" src={dialog.icon} alt="" />}
        <h1 className="overlay-dialog-title">{dialog.title}</h1>
        {dialog.from && <p className="overlay-dialog-from">{dialog.from}</p>}
        {dialog.lines.length > 0 && (
          // A long message (an import preview) scrolls here, so the buttons stay on screen.
          <div className="overlay-dialog-lines">
            {dialog.lines.map((line, index) => (
              <p key={index} className="overlay-dialog-line">
                {line}
              </p>
            ))}
          </div>
        )}
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

/** The card's controls in the order the person sees them: top to bottom, then left to right (a
 * stacked button row draws the default first, the reverse of its DOM order). */
function focusables(card: HTMLElement): HTMLElement[] {
  const controls = [...card.querySelectorAll<HTMLElement>("input, select, button")].filter(
    (node) => !(node as HTMLInputElement).disabled,
  );
  const place = new Map(controls.map((node) => [node, node.getBoundingClientRect()]));
  // Stable: controls on one line keep their DOM order.
  return controls.sort((a, b) => place.get(a)!.top - place.get(b)!.top || place.get(a)!.left - place.get(b)!.left);
}

function moveFocus(card: HTMLElement, backward: boolean) {
  const controls = focusables(card);
  const current = controls.findIndex(
    (node) => node === document.activeElement || node.contains(document.activeElement),
  );
  const next = focusAfter(current, controls.length, backward);
  controls[next]?.focus();
}
