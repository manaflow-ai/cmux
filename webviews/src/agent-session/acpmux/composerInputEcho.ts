// The app's launch mark for the first key the person typed showing in a chat composer: the page
// reports `pane.inputEchoed` once, after the frame that drew the typed text, and the app marks
// `agent_pane.input_echoed` (AgentPaneModel), its time to first interaction in a launch.
//
// Only the person's typing counts: a trusted key that types a character, or a trusted `beforeinput`
// that inserts text (an IME commits through it). A draft restored by the page, a paste, a dictation or
// a native type-ahead change the text with no such event and never report. After its one report the
// listeners leave the document, so typing costs nothing more for the rest of the page's life.

/// The composer's editor, whose text the person sees (MarkdownField's root in the composer prompt).
const EDITOR = ".acpmux-composer-prompt .acpmux-md-root";
/// The `beforeinput` kinds that are typing: a typed character, and an IME's composed text.
const TYPED_INPUT = new Set(["insertText", "insertCompositionText"]);

export type InputEchoDeps = {
  /// Sends the report to the app.
  post: () => void;
  /// Runs `run` after the next frame has drawn: a frame, then the task after it, as `pane.painted` waits.
  afterPaint?: (run: () => void) => void;
  /// Whether the event came from the person (`isTrusted`; tests stand in for it).
  trusted?: (event: Event) => boolean;
};

const nextPaint = (run: () => void) => requestAnimationFrame(() => setTimeout(run, 0));

/// Whether `event` is the person typing text: a character key with no Command or Control (those are
/// shortcuts, a paste among them), or an input that inserts typed text.
function typesText(event: Event): boolean {
  if (event.type === "beforeinput") return TYPED_INPUT.has((event as InputEvent).inputType);
  const key = event as KeyboardEvent;
  return key.key?.length === 1 && !key.metaKey && !key.ctrlKey;
}

/// Watches `doc` for the first typed text that shows in a composer and reports it once. Returns the
/// stop, which the report runs itself.
export function watchInputEcho(doc: Document, deps: InputEchoDeps): () => void {
  const afterPaint = deps.afterPaint ?? nextPaint;
  const trusted = deps.trusted ?? ((event: Event) => event.isTrusted);
  let waiting = false;
  let done = false;
  const stop = () => {
    done = true;
    doc.removeEventListener("keydown", onTyped, true);
    doc.removeEventListener("beforeinput", onTyped, true);
  };
  function onTyped(event: Event) {
    if (done || waiting || !trusted(event) || !typesText(event)) return;
    const editor = event.target instanceof doc.defaultView!.Element ? event.target.closest(EDITOR) : null;
    if (!editor) return;
    const before = editor.textContent ?? "";
    waiting = true;
    afterPaint(() => {
      waiting = false;
      // A key the editor took for something else (a shortcut, a picker) typed nothing: wait for the next.
      if (done || !editor.isConnected || (editor.textContent ?? "") === before) return;
      stop();
      deps.post();
    });
  }
  doc.addEventListener("keydown", onTyped, true);
  doc.addEventListener("beforeinput", onTyped, true);
  return stop;
}
