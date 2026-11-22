// The editor's link overlays as state: the hover card and the link popover. The editor (ProseMirror
// plugins, linkEditing.tsx) writes it; the page's React tree renders it (LinkOverlayHost in
// linkOverlays.tsx), so the overlays live in the page's one React root and its UiProvider.
import type { UiAnchor } from "../../ui/Popover";

export interface LinkCardInfo {
  target: string;
  detail: string;
  state: string;
}

export interface LinkPopoverState {
  /** Bumped per opening, so a new opening gets a fresh field. */
  id: number;
  anchor: UiAnchor;
  initial: string;
  label: string;
  placeholder: string;
  suggest(value: string): Promise<string[]>;
  onApply(href: string): void;
  onCancel(): void;
}

export interface LinkOverlayState {
  card: { anchor: Element; info: LinkCardInfo } | null;
  popover: LinkPopoverState | null;
}

export class LinkOverlays {
  private state: LinkOverlayState = { card: null, popover: null };
  private readonly listeners = new Set<() => void>();

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getState = (): LinkOverlayState => this.state;

  setCard(card: LinkOverlayState["card"]): void {
    if (card === this.state.card) return;
    this.state = { ...this.state, card };
    this.emit();
  }

  setPopover(popover: LinkPopoverState | null): void {
    if (popover === this.state.popover) return;
    this.state = { ...this.state, popover };
    this.emit();
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}
