import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { GalleryDialog } from "./GalleryDialog";
import { chatGallery } from "./chatGallery";
import { sessionSummary } from "./sessionSummary";
import { PinnedSummary } from "./PinnedSummary";
import { SummaryPopover } from "./SummaryPopover";
import { Popover } from "../../../ui/Popover";
import type { SummarySectionInput } from "./summaryModel";
import { registerPicker } from "../pickerOpeners";

const OPEN_STATE_KEY = "agentPane.summary.open";
const LEGACY_PIN_KEY = "agentPane.summary.pinned";

function storedOpenState(): boolean {
  try {
    const stored = globalThis.window?.localStorage.getItem(OPEN_STATE_KEY);
    if (stored === "true" || stored === "false") return stored === "true";
    // Preserve a user's choice from the first pinned-summary implementation when upgrading.
    return globalThis.window?.localStorage.getItem(LEGACY_PIN_KEY) !== "false";
  } catch {
    return true;
  }
}

/// The header's summary button. Modern agent panes use a persistent docked panel; the legacy
/// transcript-only surface keeps its existing summary popover until that surface is retired.
export function SummaryButton({
  rows,
  onOpenOutput,
  onOpenImage,
  cwd,
  projectName,
  sections,
  onOpenChanges,
}: {
  rows: readonly AcpmuxRow[];
  onOpenOutput?: (path: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  cwd?: string;
  projectName?: string;
  sections?: readonly SummarySectionInput[];
  onOpenChanges?: () => void;
}) {
  const t = useT();
  const modern = cwd !== undefined || sections !== undefined;
  const [open, setOpen] = useState(() => modern && storedOpenState());
  const [wide, setWide] = useState(modern);
  const [gallery, setGallery] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLElement>(null);
  const focusPanelOnOpen = useRef(false);
  const refocus = useRef(false);
  const setSummaryOpen = useCallback(
    (next: boolean) => {
      setOpen(next);
      if (!modern) return;
      try {
        globalThis.window?.localStorage.setItem(OPEN_STATE_KEY, String(next));
      } catch {
        /* storage is unavailable in opaque gallery documents */
      }
    },
    [modern],
  );
  const toggleSummary = useCallback(
    (focusPanel = false) => {
      if (focusPanel) focusPanelOnOpen.current = true;
      setSummaryOpen(!open);
    },
    [open, setSummaryOpen],
  );
  useEffect(() => {
    if (!modern) return;
    const stage = button.current?.closest(".acpmux-stage");
    if (!stage || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => {
      const measured = entry?.contentRect.width;
      if (typeof measured === "number" && measured > 0) setWide(measured >= 900);
    });
    observer.observe(stage);
    return () => observer.disconnect();
  }, [modern]);
  useEffect(() => {
    if (!modern) return;
    const toggleFromKeyboard = () => toggleSummary(true);
    window.addEventListener("cmux-acpmux-toggle-summary", toggleFromKeyboard);
    return () => window.removeEventListener("cmux-acpmux-toggle-summary", toggleFromKeyboard);
  }, [modern, toggleSummary]);
  useEffect(() => {
    if (!open || !focusPanelOnOpen.current) return;
    focusPanelOnOpen.current = false;
    requestAnimationFrame(() => panel.current?.focus());
  }, [open]);
  const closeGallery = () => {
    refocus.current = true;
    setGallery(false);
  };
  const summary = useMemo(() => sessionSummary(rows), [rows]);
  const galleryCount = useMemo(() => (open ? chatGallery(rows).length : 0), [open, rows]);
  const label = t("summary.open");
  useEffect(() => registerPicker(label, () => setSummaryOpen(true)), [label, setSummaryOpen]);
  useEffect(() => {
    if (gallery || !refocus.current) return;
    refocus.current = false;
    button.current?.focus();
  }, [gallery]);
  const panelMode = wide ? "wide" : "narrow";
  return (
    <span className="acpmux-summary">
      <button
        ref={button}
        type="button"
        className="acpmux-summary-button"
        aria-label={label}
        title={label}
        aria-expanded={open}
        onClick={() => toggleSummary()}
      >
        <Icon name="view.list" size={15} />
      </button>
      {!modern && open && (
        <Popover
          open={open}
          onOpenChange={(next) => setOpen(next)}
          anchor={button.current}
          label={label}
          className="acpmux-summary-popover"
          finalFocus={button}
        >
          <SummaryPopover
            summary={summary}
            galleryCount={galleryCount}
            onFollow={() => setOpen(false)}
            onOpenOutput={
              onOpenOutput &&
              ((path) => {
                setOpen(false);
                onOpenOutput(path);
              })
            }
            onOpenGallery={() => {
              setOpen(false);
              setGallery(true);
            }}
          />
        </Popover>
      )}
      {modern && open && (
        <PinnedSummary
          ref={panel}
          summary={summary}
          sections={sections}
          cwd={cwd}
          projectName={projectName}
          mode={panelMode}
          onClose={() => {
            setSummaryOpen(false);
            button.current?.focus();
          }}
          onOpenChanges={onOpenChanges}
        />
      )}
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={closeGallery}
          onOpenImage={
            onOpenImage &&
            ((src, alt) => {
              setGallery(false);
              onOpenImage(src, alt);
            })
          }
        />
      )}
    </span>
  );
}
