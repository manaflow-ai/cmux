// "New since you looked": when the person comes back to a chat that kept working, a quiet line marks
// where they left off (acpmux `seenSeq`, `hub/seen.rs`), with how many turns ended since. The recap
// the daemon made for the same return (`hub/away_recap.rs`) draws under it, so the two never say
// the same thing twice (Leo, 2026-11-08: "go think of things/look at things, esp valuable things
// that people would think \"wow this is awesome\""). The row is placed when the chat opens and stays
// until another chat is selected, so it never appears or goes under the reader.
import { useCallback, useSyncExternalStore } from "react";
import { useT } from "../i18n";
import type { AcpmuxSince } from "../model";
import { RecapNote } from "./RecapNote";
import { ArrowDown } from "./icons";

/// Where the drawn line is from the reader (`SinceJump`): on screen, above or below the view. The
/// virtual transcript drops a row far from the view, so a line not drawn keeps the side it left by
/// (above at first: a chat opens at its latest message). `seen`: the line was on screen once, after
/// which Jump to new has done its job and stays away for that mark.
type SinceView = { mark: string; side: "in" | "above" | "below"; seen: boolean };
let view: SinceView | undefined;
const listeners = new Set<() => void>();
function setView(next: SinceView | undefined): void {
  if (view?.mark === next?.mark && view?.side === next?.side && view?.seen === next?.seen) return;
  view = next;
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const readView = () => view;

/// Follows the drawn line's place in the transcript's scroller with one IntersectionObserver, which
/// goes with the row (a ref callback's cleanup): nothing runs per scroll frame.
function useSinceObserver(mark: string) {
  return useCallback(
    (node: HTMLElement | null) => {
      if (!node) return;
      const root = node.closest(".acpmux-scroll");
      if (view?.mark !== mark) setView({ mark, side: "above", seen: false });
      const observer = new IntersectionObserver(
        ([entry]) => {
          if (!entry) return;
          const box = entry.rootBounds;
          const side = entry.isIntersecting
            ? "in"
            : box && entry.boundingClientRect.bottom <= box.top
              ? "above"
              : "below";
          setView({ mark, side, seen: (view?.mark === mark && view.seen) || side === "in" });
        },
        { root: root instanceof HTMLElement ? root : null },
      );
      observer.observe(node);
      return () => observer.disconnect();
    },
    [mark],
  );
}

/// How the line is drawn: the label on the left of an accent hairline (shipped), the label centered
/// on the hairline, or the hairline alone with the label at its end. The gallery compares them.
export type SinceLook = "lead" | "center" | "end";

export function SinceDivider({
  since,
  onDismissRecap,
  look = "lead",
}: {
  since: AcpmuxSince;
  /// The recap's ×. Without it (a read-only transcript) the recap draws no ×.
  onDismissRecap?: () => void;
  look?: SinceLook;
}) {
  const t = useT();
  const turns = t("since.turns", { n: since.turns });
  return (
    <div className="cv-since" data-look={look} ref={useSinceObserver(since.key)}>
      <p className="cv-since__line">
        <span className="cv-since__label">{t("since.label")}</span>
        <span className="cv-since__count">{turns}</span>
      </p>
      {since.recap && <RecapNote recap={since.recap} onDismiss={onDismissRecap} lead={false} />}
    </div>
  );
}

/// Jump to new: a glass pill over the transcript's top while "New since you looked" is out of view and
/// the reader has not reached it yet. Mounted with the line's mark and only faded (conversation.css),
/// so it never pops in; `onJump` brings the line in (App.tsx, the transcript's row reveal).
export function SinceJump({ mark, onJump }: { mark: string; onJump: () => void }) {
  const t = useT();
  const where = useSyncExternalStore(subscribe, readView, readView);
  const mine = where?.mark === mark ? where : undefined;
  const shown = !mine?.seen && mine?.side !== "in";
  const label = t("since.jump");
  return (
    <button
      type="button"
      className="ui-glass acpmux-since-jump"
      data-shown={shown ? "" : undefined}
      data-side={mine?.side === "below" ? "below" : "above"}
      inert={!shown}
      title={label}
      onClick={onJump}
    >
      <span className="acpmux-since-jump__arrow" aria-hidden="true">
        <ArrowDown size={12} />
      </span>
      {label}
    </button>
  );
}
