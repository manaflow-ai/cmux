"use client";

import { useEffect } from "react";
import { useTranslations } from "next-intl";
import { Dialog } from "@base-ui-components/react/dialog";
import { DocsSearch } from "./docs-search";
import { isDocsSearchShortcut } from "./docs-search-utils";

function isEditable(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName);
}

/** Opens docs search on Cmd/Ctrl+K and "/" anywhere on the page. */
export function useDocsSearchShortcut(open: () => void) {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        !isDocsSearchShortcut({
          key: event.key,
          metaKey: event.metaKey,
          ctrlKey: event.ctrlKey,
          altKey: event.altKey,
          shiftKey: event.shiftKey,
          targetIsEditable: isEditable(event.target),
        })
      ) {
        return;
      }
      event.preventDefault();
      open();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open]);
}

/** Mintlify-style search field that opens the search dialog. */
export function DocsSearchTrigger({
  onOpen,
  compact,
}: {
  onOpen: () => void;
  compact?: boolean;
}) {
  const t = useTranslations("docs.search");
  const tu = useTranslations("docs.ui");

  if (compact) {
    return (
      <button
        type="button"
        onClick={onOpen}
        aria-label={tu("searchShortcut")}
        className="flex h-8 w-8 items-center justify-center rounded-lg text-muted transition-colors hover:bg-code-bg hover:text-foreground"
      >
        <SearchIcon />
      </button>
    );
  }

  return (
    <button
      type="button"
      onClick={onOpen}
      aria-label={tu("searchShortcut")}
      className="flex h-9 w-full items-center gap-2 rounded-xl border border-border bg-background px-3 text-left text-[13px] text-muted shadow-sm shadow-black/[0.03] transition-colors hover:border-muted/40 hover:text-foreground"
    >
      <SearchIcon />
      <span className="flex-1 truncate">{t("placeholder")}</span>
      <kbd className="rounded-md border border-border bg-code-bg px-1.5 py-0.5 font-mono text-[11px] leading-none text-muted">
        ⌘K
      </kbd>
    </button>
  );
}

function SearchIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <circle cx="11" cy="11" r="8" />
      <path d="M21 21l-4.3-4.3" />
    </svg>
  );
}

export function DocsSearchDialog({
  open,
  onOpenChange,
  onNavigate,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Runs after a result is chosen, e.g. to close the mobile nav drawer. */
  onNavigate?: () => void;
}) {
  const t = useTranslations("docs.search");

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-[1000] bg-black/40 backdrop-blur-[2px] transition-opacity duration-150 data-[ending-style]:opacity-0 data-[starting-style]:opacity-0" />
        <Dialog.Viewport className="fixed inset-0 z-[1000] flex items-start justify-center p-4 pt-[12vh]">
          <Dialog.Popup className="w-full max-w-xl overflow-hidden rounded-2xl border border-border bg-background text-foreground shadow-2xl shadow-black/20 outline-none transition duration-150 ease-out data-[ending-style]:scale-[0.98] data-[ending-style]:opacity-0 data-[starting-style]:scale-[0.98] data-[starting-style]:opacity-0">
            <Dialog.Title className="sr-only">{t("label")}</Dialog.Title>
            <DocsSearch
              onNavigate={() => {
                onOpenChange(false);
                onNavigate?.();
              }}
            />
          </Dialog.Popup>
        </Dialog.Viewport>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
