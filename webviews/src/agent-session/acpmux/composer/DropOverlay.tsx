// The drop overlay (composer/dropOverlayState.ts says when it shows and what it says; dropOverlay.css
// draws it). A faint tint over the whole chat column, which stays readable under it (Lawrence
// 2026-10-21: "needs to keep stuff behind more visible"), a dashed accent frame, and one compact
// glass pill in the middle with a mark, "Drop to attach" and what the drag holds; it lifts and brightens while the pointer is over the chat,
// turns into a plain refusal for what the chat cannot take, and on a drop shrinks into the composer,
// where the files land as chips. It never takes the pointer, so the drag's events stay the page's.
import { useLayoutEffect, useRef } from "react";
import "./dropOverlay.css";
import { createPortal } from "react-dom";
import { type StringKey, type Translate, useT } from "../i18n";
import type { DragSummary, DropOverlayState } from "./dropOverlayState";

const DROP_LABELS = {
  title: "composer.drop.title",
  refusedTitle: "composer.drop.refusedTitle",
  imagesUnsupported: "composer.imagesUnsupported",
  photos: "composer.drop.photos",
  pdf: "composer.drop.pdf",
  pdfs: "composer.drop.pdfs",
  files: "composer.drop.files",
} as const satisfies Record<string, StringKey>;

/// What the drag holds, in a few words ("3 photos", "PDF", "2 files"); empty when the engine showed
/// no items.
export function dropHint(summary: DragSummary, t: Translate): string {
  const n = summary.count;
  if (n === 0) return "";
  if (summary.kind === "photos") return t(DROP_LABELS.photos, { n });
  if (summary.kind === "pdfs") return n === 1 ? t(DROP_LABELS.pdf) : t(DROP_LABELS.pdfs, { n });
  return t(DROP_LABELS.files, { n });
}

/// The overlay for `state`. `container`: the chat column to cover (the closest `.acpmux-main`);
/// unset, it draws in place. `landingTarget`: the composer's box, the drop's destination.
/// `onLanded` runs when the landing animation ends (the overlay then hides).
export function DropOverlay({
  state,
  onLanded,
  container,
  landingTarget,
}: {
  state: DropOverlayState;
  onLanded(): void;
  container?: Element | null;
  landingTarget?: () => Element | null;
}) {
  const t = useT();
  const sheet = useRef<HTMLDivElement>(null);
  const landing = state.phase === "landing";
  // Before paint: the landing starts from where the sheet is, aimed at the composer's middle.
  useLayoutEffect(() => {
    const element = sheet.current;
    if (!landing || !element) return;
    const from = element.getBoundingClientRect();
    const to = landingTarget?.()?.getBoundingClientRect();
    if (to && from.width > 0 && from.height > 0) {
      element.style.setProperty("--acpmux-drop-fly-x", `${to.left + to.width / 2 - (from.left + from.width / 2)}px`);
      element.style.setProperty("--acpmux-drop-fly-y", `${to.top + to.height / 2 - (from.top + from.height / 2)}px`);
    }
    const end = (event: Event) => {
      if (event.target === element) onLanded();
    };
    element.addEventListener("animationend", end);
    // No animation runs (the app's animations off): nothing will end it, so it ends now.
    if (element.ownerDocument.defaultView?.getComputedStyle(element).animationName === "none") onLanded();
    return () => element.removeEventListener("animationend", end);
  }, [landing, landingTarget, onLanded]);
  if (state.phase === "hidden") return null;
  const refused = state.phase === "refused";
  const hint = dropHint(state.summary, t);
  const overlay = (
    <div className="acpmux-drop-overlay" data-phase={state.phase} data-kind={state.summary.kind} aria-hidden="true">
      <div ref={sheet} className="acpmux-drop-sheet">
        <svg className="acpmux-drop-frame" aria-hidden="true" focusable="false">
          <rect className="acpmux-drop-frame-line" />
        </svg>
        <div className="acpmux-drop-pill">
          <span className="acpmux-drop-mark">{refused ? <RefusedMark /> : <DropMark kind={state.summary.kind} />}</span>
          <span className="acpmux-drop-text">
            <span className="acpmux-drop-title">{t(refused ? DROP_LABELS.refusedTitle : DROP_LABELS.title)}</span>
            {refused ? (
              <span className="acpmux-drop-hint">{t(DROP_LABELS.imagesUnsupported)}</span>
            ) : (
              hint && <span className="acpmux-drop-hint">{hint}</span>
            )}
          </span>
        </div>
      </div>
    </div>
  );
  return container ? createPortal(overlay, container) : overlay;
}

/// The drop mark: a tray with an arrow into it, a photo stack for photos, a page for PDFs.
function DropMark({ kind }: { kind: DragSummary["kind"] }) {
  return (
    <svg
      viewBox="0 0 32 32"
      width="32"
      height="32"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {kind === "photos" ? (
        <>
          <rect x="7" y="9" width="18" height="15" rx="3" />
          <path d="M10 6h12" opacity=".55" />
          <circle cx="12.5" cy="14" r="1.6" />
          <path d="m8 22 5.5-5.5 3.5 3.5 2.5-2.5 5 5" />
        </>
      ) : kind === "pdfs" ? (
        <>
          <path d="M9.5 4.5h9l5 5v18h-14Z" />
          <path d="M18.5 4.5v5h5" />
          <path d="M12.5 16.5h7M12.5 20.5h7M12.5 24.5h4" opacity=".7" />
        </>
      ) : (
        <>
          <path d="M16 5v13" />
          <path d="m10.5 12.5 5.5 5.5 5.5-5.5" />
          <path d="M5.5 19v4.5a3 3 0 0 0 3 3h15a3 3 0 0 0 3-3V19" />
        </>
      )}
    </svg>
  );
}

/// The refusal's mark: a circle crossed out.
function RefusedMark() {
  return (
    <svg
      viewBox="0 0 32 32"
      width="32"
      height="32"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
    >
      <circle cx="16" cy="16" r="10.5" />
      <path d="m8.6 23.4 14.8-14.8" />
    </svg>
  );
}
