// The editor's link bubble as state. The editor (ProseMirror plugins, linkEditing.ts) writes it; the
// page's React tree renders it (LinkOverlayHost in linkOverlays.tsx), so the bubble lives in the
// page's one React root and its UiProvider.
//
// One bubble, two modes (Google Docs' link bubble): "view" while the caret is inside a link (its
// URL, where it goes, and Open, Copy link, Edit, Remove), and "edit" (a Text field and a URL field)
// from the bubble's Edit button or the `link` page command (Cmd-K).
import type { UiAnchor } from "../../ui/Popover";
import type { LinkLabel } from "./linkEditing";

export interface LinkCardInfo {
  target: string;
  detail: string;
  state: string;
}

export interface LinkBubbleState {
  /** Bumped per opening, so a new opening (another link, or the edit form) gets fresh fields. */
  id: number;
  mode: "view" | "edit";
  /** The link's element in view mode; the selection's box in edit mode. */
  anchor: UiAnchor;
  /** The link's href ("" for a new link). */
  href: string;
  /** The link's text (the selection for a new link). */
  text: string;
  /** Where the link goes, for the view mode's lines. */
  info: LinkCardInfo;
  /** True when the edit form makes a new link (Cmd-K with no link at the caret). */
  inserting: boolean;
  /** The page's strings for the bubble. */
  label(key: LinkLabel): string;
  /** Completion for the URL field: `#headings` of this file and workspace paths. */
  suggest(value: string): Promise<string[]>;
  /** Follows the link (the same as Cmd-click). */
  open(): void;
  /** Copies the href to the clipboard (`fallback`: a hidden textarea for the copy command). */
  copy(fallback?: HTMLTextAreaElement | null): void;
  /** Switches the bubble to the edit form. */
  edit(): void;
  /** Removes the link, keeping its text. */
  remove(): void;
  /** Saves the edit form: the text and the href (an empty href removes the link). */
  apply(text: string, href: string): void;
  /** Closes the edit form (Escape) and returns to the editor unchanged. */
  cancel(): void;
}

export interface LinkOverlayState {
  bubble: LinkBubbleState | null;
}

export class LinkOverlays {
  private state: LinkOverlayState = { bubble: null };
  private readonly listeners = new Set<() => void>();

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getState = (): LinkOverlayState => this.state;

  setBubble(bubble: LinkBubbleState | null): void {
    if (bubble === this.state.bubble) return;
    this.state = { bubble };
    this.emit();
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}
