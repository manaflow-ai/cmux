"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import type { ReactNode } from "react";

/**
 * A reusable centered modal built on Base UI `Dialog`. Renders a dimmed
 * backdrop (no blur) and a card that fades and gently scales in/out. Children
 * provide the contents and may use `Dialog.Title`, `Dialog.Description`, and
 * `Dialog.Close` directly (Base UI wires them through context).
 *
 * ```tsx
 * <Modal open={open} onOpenChange={setOpen}>
 *   <Dialog.Title>Title</Dialog.Title>
 *   …
 * </Modal>
 * ```
 */
export function Modal({
  open,
  onOpenChange,
  children,
  className,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  children: ReactNode;
  /** Extra classes for the popup card (e.g. a wider `max-w`). */
  className?: string;
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-[1000] bg-black/50 transition-opacity duration-200 ease-out data-[ending-style]:opacity-0 data-[starting-style]:opacity-0" />
        <Dialog.Viewport className="fixed inset-0 z-[1000] flex items-center justify-center overflow-y-auto p-4">
          <Dialog.Popup
            className={`w-full max-w-md origin-center rounded-2xl border border-border bg-background p-6 text-foreground shadow-xl shadow-black/10 outline-none transition duration-200 ease-out data-[ending-style]:scale-[0.98] data-[ending-style]:opacity-0 data-[starting-style]:scale-[0.98] data-[starting-style]:opacity-0 ${
              className ?? ""
            }`}
          >
            {children}
          </Dialog.Popup>
        </Dialog.Viewport>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
