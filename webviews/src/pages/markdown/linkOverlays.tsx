// The editor's link bubble, as React over the ui wrapper (Google Docs' link bubble). View mode: a
// card under the link at the caret (ui AnchoredCard) with the URL, where it goes and a toolbar of
// Copy link, Edit and Remove; the URL itself opens the link. It never takes focus, so typing goes
// on in the editor. Edit mode: a form (ui Popover) with a Text field and a URL field (ui Combobox,
// completing `#headings` and workspace paths), Apply and Remove. linkEditing.ts decides when the
// bubble shows and what its actions do (LinkOverlays state); these only render.
import { useEffect, useRef, useState, useSyncExternalStore, type FormEvent, type ReactNode } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { AnchoredCard } from "../../ui/Tooltip";
import { Toolbar, ToolbarButton } from "../../ui/Toolbar";
import type { LinkBubbleState, LinkOverlays } from "./overlays";

/** Renders the editor's link bubble (mount once in the page, under UiProvider). */
export function LinkOverlayHost({ overlays }: { overlays: LinkOverlays }) {
  const { bubble } = useSyncExternalStore(overlays.subscribe, overlays.getState);
  if (!bubble) return null;
  return bubble.mode === "view" ? (
    <LinkBubbleView key={bubble.id} bubble={bubble} />
  ) : (
    <LinkEditView key={bubble.id} bubble={bubble} />
  );
}

const COPIED_MS = 1200;

/** The view bubble: the URL (opens the link), where it goes, and Copy link, Edit, Remove. */
export function LinkBubbleView({ bubble }: { bubble: LinkBubbleState }) {
  const { label, info } = bubble;
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => void (timer.current && clearTimeout(timer.current)), []);
  const fallback = useRef<HTMLTextAreaElement | null>(null);
  const copy = () => {
    bubble.copy(fallback.current);
    setCopied(true);
    if (timer.current) clearTimeout(timer.current);
    // A bounded delay is the behavior: the "Copied" note shows for a moment, then the icon returns.
    timer.current = setTimeout(() => setCopied(false), COPIED_MS);
  };
  return (
    <AnchoredCard
      anchor={bubble.anchor}
      className="md-link-bubble"
      state={info.state}
      interactive
      ariaLabel={label("bubble")}
    >
      <div className="md-link-bubble-row">
        <button
          type="button"
          className="md-link-bubble-target"
          // tooltip-allow: the full URL when the bubble truncates it
          title={bubble.href}
          // The editor keeps the focus and the caret (Google Docs' bubble never takes them).
          onMouseDown={(event) => event.preventDefault()}
          onClick={(event) => {
            event.preventDefault();
            bubble.open();
          }}
          aria-label={`${label("open")}: ${info.target}`}
        >
          <LinkGlyph />
          <span className="md-link-bubble-url">{info.target}</span>
        </button>
        <Toolbar className="md-link-bubble-actions" label={label("bubble")}>
          <ToolbarButton label={copied ? label("copied") : label("copy")} tooltip={false} keepsFocus onPress={copy}>
            {copied ? <CheckGlyph /> : <CopyGlyph />}
          </ToolbarButton>
          <ToolbarButton label={label("edit")} tooltip={false} keepsFocus onPress={() => bubble.edit()}>
            <EditGlyph />
          </ToolbarButton>
          <ToolbarButton label={label("remove")} keepsFocus onPress={() => bubble.remove()}>
            <UnlinkGlyph />
          </ToolbarButton>
        </Toolbar>
      </div>
      <div className="md-link-bubble-detail">{info.detail}</div>
      <span className="md-visually-hidden" aria-live="polite">
        {copied ? label("copied") : ""}
      </span>
      <textarea
        ref={fallback}
        className="md-visually-hidden"
        // ui-allow: the copy command's hidden source text, never a Tab stop
        tabIndex={-1}
        aria-hidden="true"
        readOnly
      />
    </AnchoredCard>
  );
}

const MAX_SUGGESTIONS = 12;

/** The edit form: Text and URL fields; Return applies, Escape cancels, Remove unlinks. */
export function LinkEditView({ bubble }: { bubble: LinkBubbleState }) {
  const { label } = bubble;
  const [items, setItems] = useState<string[]>([]);
  const ticket = useRef(0);
  const textField = useRef<HTMLInputElement | null>(null);
  const urlField = useRef<HTMLInputElement | null>(null);
  const started = useRef(false);
  const href = useRef(bubble.href);
  const query = (value: string) => {
    href.current = value;
    const id = ++ticket.current;
    void bubble.suggest(value).then(
      (next) => {
        if (id === ticket.current) setItems(next.slice(0, MAX_SUGGESTIONS));
      },
      () => {
        if (id === ticket.current) setItems([]);
      },
    );
  };
  // A callback ref: the URL field takes focus with its text selected, and the first suggestions load.
  const urlRef = (element: HTMLInputElement | null) => {
    urlField.current = element;
    if (!element || started.current) return;
    started.current = true;
    element.focus({ preventScroll: true });
    element.select();
    query(bubble.href);
  };
  const apply = (value = href.current) => bubble.apply(textField.current?.value ?? bubble.text, value.trim());
  const submit = (event: FormEvent) => {
    event.preventDefault();
    apply();
  };
  return (
    <Popover
      open
      onOpenChange={(open) => !open && bubble.cancel()}
      anchor={bubble.anchor}
      label={label(bubble.inserting ? "insertTitle" : "editTitle")}
      className="md-link-popover"
      initialFocus={urlField}
      finalFocus={false}
    >
      <form className="md-link-form" onSubmit={submit}>
        <label className="md-link-field">
          <span className="md-link-field-label">{label("text")}</span>
          <input
            ref={textField}
            className="md-link-input md-link-text"
            defaultValue={bubble.text}
            aria-label={label("text")}
            placeholder={label("textPlaceholder")}
          />
        </label>
        <div className="md-link-field">
          <span className="md-link-field-label" aria-hidden="true">
            {label("url")}
          </span>
          <Combobox
            inline
            inputRef={urlRef}
            defaultValue={bubble.href}
            suggestions={items}
            onQuery={query}
            onSubmit={(value) => apply(value)}
            onCancel={() => bubble.cancel()}
            cancelOnBlur={false}
            label={label("linkPlaceholder")}
            placeholder={label("linkPlaceholder")}
            inputClassName="md-link-input"
            listClassName="md-link-suggestions"
          />
        </div>
        <div className="md-link-form-actions">
          {bubble.inserting ? null : (
            <button type="button" className="ui-button md-link-remove" onClick={() => bubble.remove()}>
              {label("remove")}
            </button>
          )}
          <button type="submit" className="ui-button md-link-apply">
            {label("apply")}
          </button>
        </div>
      </form>
    </Popover>
  );
}

function Glyph({ children }: { children: ReactNode }) {
  return (
    <svg className="md-link-glyph" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">
      {children}
    </svg>
  );
}

const STROKE = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.4,
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

function LinkGlyph() {
  return (
    <Glyph>
      <path
        {...STROKE}
        d="M6.5 9.5l3-3M7 4.5l1.2-1.2a2.6 2.6 0 0 1 3.7 3.7L10.7 8.2M9 11.5l-1.2 1.2a2.6 2.6 0 0 1-3.7-3.7L5.3 7.8"
      />
    </Glyph>
  );
}

function CopyGlyph() {
  return (
    <Glyph>
      <rect {...STROKE} x="5.5" y="5.5" width="8" height="8" rx="1.5" />
      <path {...STROKE} d="M10.5 3.5v-.5a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h.5" />
    </Glyph>
  );
}

function CheckGlyph() {
  return (
    <Glyph>
      <path {...STROKE} d="M3.5 8.5l3 3 6-7" />
    </Glyph>
  );
}

function EditGlyph() {
  return (
    <Glyph>
      <path {...STROKE} d="M10.5 3l2.5 2.5L6 12.5H3.5V10z" />
    </Glyph>
  );
}

function UnlinkGlyph() {
  return (
    <Glyph>
      <path
        {...STROKE}
        d="M7 4.5l1.2-1.2a2.6 2.6 0 0 1 3.7 3.7L10.7 8.2M9 11.5l-1.2 1.2a2.6 2.6 0 0 1-3.7-3.7L5.3 7.8M2.5 2.5l11 11"
      />
    </Glyph>
  );
}
