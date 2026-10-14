// A turn's "Worked for" fold moves rather than jumps (cx-o90g7): when a turn ends and its steps
// fold away, and when the reader opens or closes the fold, the rows that stay slide from where they
// were drawn to their new places, the steps that appear fade in and the ones that go fade out. Rows
// are placed absolutely (App.tsx RowFrame), so nothing animates a height: each row's `translate`
// (which its inline `transform` placement leaves alone) runs from its old place to none, the way the
// New Tab list moves (newtab/listMotion.ts).
//
// A change is armed before it commits, with where each mounted row is drawn. Its first commit
// places rows by estimated heights, and their drawn heights land before the frame paints, so that
// commit holds every row where it was; the next frame, with the final places, starts the slides.
// Durations are the motion tokens: Reduce Motion keeps only a short fade, animation speed off
// (tokens 0) none.

/// How the fold moves: `slide` (rows slide, steps fade), `fade` (rows jump, steps fade) or `none`.
/// The page reads `#foldMotion=` so captures can compare them; `slide` is the default.
export type FoldMotionMode = "slide" | "fade" | "none";

export function foldMotionMode(hash = globalThis.location?.hash ?? ""): FoldMotionMode {
  const value = new URLSearchParams(hash.replace(/^#/, "")).get("foldMotion");
  return value === "fade" || value === "none" ? value : "slide";
}

type Armed = {
  /// Where each mounted row was drawn, as its top on screen.
  before: Map<string, number>;
  /// The fold header the reader toggled, which keeps its place on screen.
  anchor?: string;
  /// Rows that left in this change, as copies to fade out where they were.
  leaving: { node: HTMLElement; top: number }[];
  held: boolean;
  thread: HTMLElement;
};

const STALE_MS = 500;

const rowsOf = (thread: HTMLElement) => [...thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]")];

function seconds(value: string): number {
  const text = value.trim();
  if (!text) return 0;
  const number = Number.parseFloat(text);
  if (!Number.isFinite(number)) return 0;
  return text.endsWith("ms") ? number / 1000 : number;
}

export class FoldMotion {
  private armed: Armed | undefined;
  private running: Animation[] = [];
  private frame = 0;

  constructor(private readonly mode: FoldMotionMode = foldMotionMode()) {}

  /// Whether a change is in flight: the transcript neither glides nor follows meanwhile.
  get active(): boolean {
    return this.armed !== undefined;
  }

  /// The header a reader's toggle keeps in place, while that change is in flight.
  get anchor(): string | undefined {
    return this.armed?.anchor;
  }

  /// Arms the next commit: `thread` is drawn as it was before it.
  arm(thread: HTMLElement | null, anchor?: string): void {
    if (this.mode === "none" || !thread) return;
    this.finish();
    const before = new Map<string, number>();
    for (const row of rowsOf(thread)) before.set(row.dataset.rowId!, row.getBoundingClientRect().top);
    const armed: Armed = { before, anchor, leaving: [], held: false, thread };
    this.armed = armed;
    // A change that never commits does not keep the transcript from gliding and following.
    setTimeout(() => {
      if (this.armed === armed && !armed.held) this.finish();
    }, STALE_MS);
  }

  /// A row unmounts while a change is armed: a copy of it fades out where it was.
  leave(id: string, node: HTMLElement): void {
    const armed = this.armed;
    if (!armed || armed.held) return;
    const top = armed.before.get(id);
    if (top === undefined) return;
    const copy = node.cloneNode(true) as HTMLElement;
    copy.removeAttribute("id");
    copy.removeAttribute("tabindex");
    copy.removeAttribute("data-row-id");
    copy.setAttribute("aria-hidden", "true");
    copy.inert = true;
    copy.style.pointerEvents = "none";
    armed.leaving.push({ node: copy, top });
  }

  /// After the armed change commits (and the scroll is placed): hold each row where it was, then
  /// slide it the next frame.
  committed(thread: HTMLElement | null): void {
    const armed = this.armed;
    if (!armed || armed.held || !thread) return;
    armed.held = true;
    const style = getComputedStyle(thread);
    const reduced = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const move = this.mode === "slide" && !reduced ? seconds(style.getPropertyValue("--agent-motion-move")) * 1000 : 0;
    const appear = Math.min(seconds(style.getPropertyValue("--agent-motion-in")) * 1000, reduced ? 100 : Infinity);
    const go = Math.min(seconds(style.getPropertyValue("--agent-motion-out")) * 1000, reduced ? 100 : Infinity);
    const easing = style.getPropertyValue("--agent-ease-out").trim() || "ease-out";
    if (move <= 0 && appear <= 0 && go <= 0) {
      this.armed = undefined;
      return;
    }
    // Hold: the rows that stay where they were drawn, the new ones hidden, until the next frame.
    const rows = rowsOf(thread);
    for (const row of rows) {
      const was = armed.before.get(row.dataset.rowId!);
      if (was === undefined) {
        if (appear > 0) row.style.opacity = "0";
      } else if (move > 0) {
        const shift = was - row.getBoundingClientRect().top;
        if (Math.abs(shift) > 0.5) row.style.translate = `0 ${shift}px`;
      }
    }
    for (const leaving of armed.leaving) {
      if (go <= 0) continue;
      thread.append(leaving.node);
      const shift = leaving.top - leaving.node.getBoundingClientRect().top;
      leaving.node.style.translate = `0 ${shift}px`;
    }
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      const now = rowsOf(thread);
      // Reads, then writes: the final place of every row, then its slide.
      for (const row of now) row.style.translate = "";
      const places = now.map((row) => row.getBoundingClientRect().top);
      for (const [index, row] of now.entries()) {
        const was = armed.before.get(row.dataset.rowId!);
        if (was === undefined) {
          row.style.opacity = "";
          // Steps a reader opens fade in once the rows below have mostly moved out of their way; at
          // a turn's end the rows that arrive cross the steps fading out, so nothing blinks empty.
          if (appear > 0)
            this.running.push(
              row.animate([{ opacity: 0 }, { opacity: 1 }], {
                duration: appear,
                delay: armed.anchor === undefined ? 0 : move * 0.6,
                easing,
                fill: "backwards",
              }),
            );
          continue;
        }
        const shift = was - places[index]!;
        if (move > 0 && Math.abs(shift) > 0.5)
          this.running.push(
            row.animate([{ translate: `0 ${shift}px` }, { translate: "0 0" }], { duration: move, easing }),
          );
      }
      for (const leaving of armed.leaving) {
        if (!leaving.node.isConnected) continue;
        const fade = leaving.node.animate([{ opacity: 1 }, { opacity: 0 }], { duration: go, easing, fill: "forwards" });
        fade.onfinish = () => leaving.node.remove();
        fade.oncancel = () => leaving.node.remove();
        this.running.push(fade);
      }
      if (this.running.length === 0) this.armed = undefined;
      else
        void Promise.allSettled(this.running.map((animation) => animation.finished)).then(() => {
          if (this.armed === armed) this.armed = undefined;
        });
    });
  }

  /// Ends a change at once (a new one starts, the transcript unmounts or switches chats).
  finish(): void {
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = 0;
    for (const animation of this.running) animation.cancel();
    this.running = [];
    const armed = this.armed;
    this.armed = undefined;
    if (!armed) return;
    for (const leaving of armed.leaving) leaving.node.remove();
    // A change ended between its hold and its first frame: put the held rows back.
    for (const row of rowsOf(armed.thread)) {
      row.style.translate = "";
      row.style.opacity = "";
    }
  }
}
