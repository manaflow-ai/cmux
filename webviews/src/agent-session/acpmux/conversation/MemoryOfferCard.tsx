import { memo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { useT } from "../i18n";
import { Check, Close } from "./icons";
import { actionableFacts, memoryCardState, type MemoryOffer } from "./memoryInbox";
import "./cardFit.css";
import "./MemoryOfferCard.css";

/// How the card is drawn. `diff` (shipped): the facts as `+` lines of a small diff, Accept and
/// Dismiss always on each line. `hover`: the same diff, its actions only on the hovered or focused
/// line. `checklist`: a box per fact, all ticked, and one Accept for the ticked ones (the rest are
/// dismissed). The gallery compares them (MemoryOfferCard.gallery.tsx).
export type MemoryCardLook = "diff" | "hover" | "checklist";

/// Opens and closes its content's height (a grid row from 0fr to 1fr), so a settled fact shrinks
/// away and the card folds to its note with no jump. Closed, its content is inert: no focus, no
/// clicks. Reduced motion settles it in one frame (MemoryOfferCard.css).
function Fold({ open, className, children }: { open: boolean; className?: string; children: ReactNode }) {
  return (
    <div className={className ? `cv-memory__fold ${className}` : "cv-memory__fold"} data-open={open} inert={!open}>
      <div className="cv-memory__clip">{children}</div>
    </div>
  );
}

/// The memory inbox (memoryInbox.ts): facts acpmux offers for the project's instructions file after
/// a turn in which the person corrected the agent, drawn under that turn as a small diff of the
/// file. Accept writes a fact (`onResolve`, `_acpmux/memory_resolve`); Dismiss drops it. With focus
/// inside, `a` or Return accepts the focused fact, `d`, Delete or Backspace dismisses it and the
/// arrows move between facts; the card never takes focus by itself, so the composer keeps it.
/// Each settled fact's line shrinks away; once all are settled the card folds to one line.
/// Without `onResolve` (a replay, a read-only transcript) it draws the facts with no buttons.
export const MemoryOfferCard = memo(function MemoryOfferCard({
  offer,
  onResolve,
  look = "diff",
}: {
  offer: MemoryOffer;
  onResolve?: (accept: string[], dismiss: string[]) => void;
  look?: MemoryCardLook;
}) {
  const t = useT();
  const card = memoryCardState(offer);
  const open = actionableFacts(card);
  const list = useRef<HTMLDivElement>(null);
  // In the checklist, the boxes the person cleared: the facts its Accept dismisses.
  const unticked = useRef(new Set<string>());
  const actions = onResolve !== undefined;
  // The last error stays in its fold while the fold closes, so the line shrinks instead of blanking.
  const [shownError, setShownError] = useState(card.error);
  if (card.error && card.error !== shownError) setShownError(card.error);

  const lines = () => [...(list.current?.querySelectorAll<HTMLElement>("[data-fact-line]:not([inert] *)") ?? [])];
  const focusFact = (from: HTMLElement | undefined, step: 1 | -1) => {
    const all = lines();
    const at = from ? all.indexOf(from) : -1;
    all[at + step]?.focus();
  };
  const resolve = (fact: string, accept: boolean, line?: HTMLElement) => {
    if (!onResolve || !open.includes(fact)) return;
    // The next open fact takes focus before this one's line folds (and goes inert).
    if (line && line.contains(line.ownerDocument.activeElement)) {
      const all = lines();
      const at = all.indexOf(line);
      (all[at + 1] ?? all[at - 1])?.focus();
    }
    onResolve(accept ? [fact] : [], accept ? [] : [fact]);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!actions || event.metaKey || event.ctrlKey || event.altKey || event.nativeEvent.isComposing) return;
    const line = (event.target as HTMLElement).closest<HTMLElement>("[data-fact-line]");
    if (!line) return;
    const fact = line.dataset.fact ?? "";
    // Return and Space on a button or a box are the control's own.
    const onButton = ["BUTTON", "INPUT"].includes((event.target as HTMLElement).tagName);
    const key = event.key;
    if (key === "ArrowDown" || key === "ArrowUp") focusFact(line, key === "ArrowDown" ? 1 : -1);
    else if (key === "a" || (key === "Enter" && !onButton)) resolve(fact, true, line);
    else if (key === "d" || key === "Delete" || key === "Backspace") resolve(fact, false, line);
    else return;
    event.preventDefault();
    event.stopPropagation();
  };
  const acceptAll = () => {
    if (!onResolve || !open.length) return;
    if (look !== "checklist") return onResolve(open, []);
    onResolve(
      open.filter((fact) => !unticked.current.has(fact)),
      open.filter((fact) => unticked.current.has(fact)),
    );
  };
  // The first open fact is the one Tab reaches; the arrows reach the rest.
  const tabStop = open[0];
  const note =
    card.accepted > 0 ? t("memoryInbox.added", { n: card.accepted, file: card.file }) : t("memoryInbox.dismissed");
  const acceptWord = t("memoryInbox.accept");
  const dismissWord = t("memoryInbox.dismiss");
  const acceptAllWord = look === "checklist" ? acceptWord : t("memoryInbox.acceptAll");

  return (
    <section
      className="cv-memory cv-fit"
      data-look={look}
      data-settled={card.settled}
      aria-label={t("memoryInbox.label", { file: card.file })}
    >
      <Fold open={!card.settled} className="cv-memory__body">
        <div className="cv-memory__head">
          <span
            className="cv-memory__file"
            // tooltip-allow: a long memory file path is cut to the line; its whole path is the tooltip
            title={card.file}
          >
            {card.file}
          </span>
          {card.created && <span className="cv-memory__tag">{t("memoryInbox.newFile")}</span>}
        </div>
        {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- hears the keys of its focusable fact lines and their buttons. */}
        <div className="cv-memory__diff" ref={list} onKeyDown={onKeyDown}>
          {offer.heading && (
            <Fold open={card.heading !== null}>
              <div className="cv-memory__line cv-memory__line--heading" aria-hidden="true">
                <span className="cv-memory__main cv-fit-text">
                  <span className="cv-memory__sign">+</span>
                  <span className="cv-memory__text">{offer.heading}</span>
                </span>
              </div>
            </Fold>
          )}
          {card.facts.map((fact) => {
            const waiting = fact.state === "pending" || fact.state === "busy";
            const busy = fact.state === "busy";
            return (
              <Fold key={fact.text} open={waiting}>
                <div
                  className="cv-memory__line cv-fit-row"
                  data-fact-line=""
                  data-fact={fact.text}
                  data-state={fact.state}
                  aria-busy={busy || undefined}
                  tabIndex={actions && waiting ? (fact.text === tabStop ? 0 : -1) : undefined}
                >
                  <span className="cv-memory__main cv-fit-text">
                    {look === "checklist" && actions && (
                      <input
                        type="checkbox"
                        className="cv-memory__check"
                        defaultChecked
                        disabled={busy}
                        aria-label={fact.text}
                        onChange={(event) => {
                          if (event.target.checked) unticked.current.delete(fact.text);
                          else unticked.current.add(fact.text);
                        }}
                      />
                    )}
                    <span className="cv-memory__sign" aria-hidden="true">
                      +
                    </span>
                    <span className="cv-memory__text">- {fact.text}</span>
                  </span>
                  {actions && look !== "checklist" && (
                    <span className="cv-memory__actions cv-fit-actions">
                      <button
                        type="button"
                        className="cv-memory__button is-accept"
                        disabled={busy}
                        aria-keyshortcuts="A Enter"
                        title={acceptWord}
                        aria-label={acceptWord}
                        onClick={(event) =>
                          resolve(fact.text, true, event.currentTarget.closest("[data-fact-line]") as HTMLElement)
                        }
                      >
                        <Check size={14} />
                        <span className="cv-fit-label">{acceptWord}</span>
                      </button>
                      <button
                        type="button"
                        className="cv-memory__button"
                        disabled={busy}
                        aria-keyshortcuts="D Delete Backspace"
                        title={dismissWord}
                        aria-label={dismissWord}
                        onClick={(event) =>
                          resolve(fact.text, false, event.currentTarget.closest("[data-fact-line]") as HTMLElement)
                        }
                      >
                        <Close size={14} />
                        <span className="cv-fit-label">{dismissWord}</span>
                      </button>
                    </span>
                  )}
                </div>
              </Fold>
            );
          })}
        </div>
        {actions && (
          <Fold open={look === "checklist" ? open.length > 0 : open.length > 1}>
            <div className="cv-memory__foot cv-fit-actions">
              <button
                type="button"
                className="cv-memory__button is-accept"
                title={acceptAllWord}
                aria-label={acceptAllWord}
                onClick={acceptAll}
              >
                <Check size={14} />
                <span className="cv-fit-label">{acceptAllWord}</span>
              </button>
            </div>
          </Fold>
        )}
        <Fold open={card.error !== undefined}>
          <output className="cv-memory__error" role="alert">
            {shownError}
          </output>
        </Fold>
      </Fold>
      <Fold open={card.settled} className="cv-memory__done">
        <p className="cv-memory__note">{note}</p>
      </Fold>
    </section>
  );
});
