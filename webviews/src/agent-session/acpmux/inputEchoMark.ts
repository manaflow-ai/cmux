// The chat's launch input mark: the first frame after the composer drew a key the person typed. The page
// reports `pane.inputEchoed` once per page life; the app turns it into the launch mark
// `agent_pane.input_echoed` (AgentPaneModel.swift), the chat's first-input number in
// scripts/ci/launch_tti_check.py beside the terminal's `terminal_echo`.
//
// Leo, 2026-11-22: "the agent pane loads pretty slow. [...] we should be able to just show it up as fast as
// the terminal does."
//
// A one-shot: a typed printable key in the composer's prompt arms it, the frame after that key's draw
// checks the prompt's text changed and posts; a key the prompt did not take (still loading, a shortcut)
// leaves it armed for the next. After the post every listener is gone; nothing runs on a timer.

/// The prompt field a key went to: an editable element inside the composer.
export function composerField(target: EventTarget | null): Element | null {
  const element = target as (Element & { isContentEditable?: boolean }) | null;
  if (!element || typeof element.closest !== "function") return null;
  const editable =
    element.isContentEditable === true || element.tagName === "TEXTAREA" || element.closest("[contenteditable]");
  if (!editable) return null;
  return element.closest(".acpmux-composer") ? element : null;
}

/// A key that types a character: one character, no command modifier, not an input method composing.
export function typesCharacter(event: KeyboardEvent): boolean {
  if (event.isComposing || event.keyCode === 229) return false;
  if (event.metaKey || event.ctrlKey) return false;
  return typeof event.key === "string" && event.key.length === 1;
}

function fieldText(field: Element): string {
  const value = (field as Element & { value?: unknown }).value;
  return typeof value === "string" ? value : (field.textContent ?? "");
}

export type InputEchoDeps = {
  /// Where keys arrive (the page's document).
  target: Pick<EventTarget, "addEventListener" | "removeEventListener">;
  /// Sends the report (callNative("pane.inputEchoed")).
  post: () => void;
  /// Runs `run` after the next frame is painted (rAF, then a task: the frame that rAF preceded is on screen).
  afterPaint: (run: () => void) => void;
  /// Whether the key came from the person (`isTrusted`); a page script's synthetic key is not one.
  trusted?: (event: KeyboardEvent) => boolean;
};

let watching: (() => void) | undefined;
let reported = false;

/// Starts the one-shot watch, once per page life (a second call while it runs or after it posted does
/// nothing). Returns the stop function.
export function watchFirstInputEcho(deps: InputEchoDeps): () => void {
  if (reported) return () => {};
  if (watching) return watching;
  const trusted = deps.trusted ?? ((event: KeyboardEvent) => event.isTrusted);
  let pending = false;
  const onKey = (event: Event) => {
    if (reported || pending) return;
    const key = event as KeyboardEvent;
    if (!trusted(key) || !typesCharacter(key)) return;
    const field = composerField(key.target);
    if (!field) return;
    const before = fieldText(field);
    pending = true;
    // The key's edit lands in the field in keydown's own task, so the next frame draws it; the task
    // after that frame's rAF runs once it is painted.
    deps.afterPaint(() => {
      pending = false;
      if (reported || fieldText(field) === before) return;
      reported = true;
      stop();
      deps.post();
    });
  };
  const stop = () => {
    deps.target.removeEventListener("keydown", onKey, true);
    watching = undefined;
  };
  deps.target.addEventListener("keydown", onKey, true);
  watching = stop;
  return stop;
}

/// The page's watch: the document's keys, posted through the app's bridge.
export function startInputEchoMark(post: () => void): void {
  if (typeof document === "undefined" || typeof requestAnimationFrame !== "function") return;
  watchFirstInputEcho({
    target: document,
    post,
    afterPaint: (run) => requestAnimationFrame(() => setTimeout(run, 0)),
  });
}

/// Tests only: a fresh page life.
export function resetInputEchoMarkForTests(): void {
  watching?.();
  watching = undefined;
  reported = false;
}
