// PromptEditor (Milkdown, about half a megabyte of script) as its own chunk, for a page whose
// startup should not wait on it (Home Channels' composer). Until the chunk arrives it draws the
// field's own pre-editor box (markdownFieldFrame.tsx), the one PromptEditor draws until its editor
// is made: the same box, placeholder and height from the first frame, so nothing moves when the
// editor takes over. The chunk is fetched once the page is idle after its first frame, or at once
// when the field is pressed, focused or asked for focus.
//
// The handle works from the start. Focus asked for early goes to the box (it takes the keyboard
// while it waits) and to the editor once it is made, as PromptEditor's own does. The keys typed
// while the box has the keyboard are kept and typed into the editor when it is ready, so no
// keystroke is lost. Only those: a key with Command, Control or Option, and every key while the
// keyboard is anywhere else (the page, another field), goes on as before, so a page shortcut
// keeps working while the editor loads. An input method cannot compose in the box (it is no text
// field): text composed before the editor is ready is not kept.
import { type FocusEvent, forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from "react";
import { lazyChunk } from "../../../lazyChunk";
import { focusRoute } from "../../../ui/focusRoute";
import { intl } from "../../../ui/intl";
import { MarkdownFieldFrame } from "../markdownFieldFrame";
import type { PromptEditorHandle, PromptEditorProps } from "./PromptEditor";

type PromptEditorModule = typeof import("./PromptEditor");
let editorModule: PromptEditorModule | undefined;
let editorLoad: Promise<PromptEditorModule> | undefined;
let importEditor = (): Promise<PromptEditorModule> => import("./PromptEditor");

/** Fetches PromptEditor's chunk once; resolves to it. */
export const loadPromptEditor = lazyChunk((): Promise<PromptEditorModule> => {
  editorLoad ??= importEditor().then(
    (module) => (editorModule = module),
    (error: unknown) => {
      // A failed fetch (a web update swapped the files) is tried again on the next ask.
      editorLoad = undefined;
      throw error;
    },
  );
  return editorLoad;
});

/**
 * Tests only: the chunk as not yet fetched, fetched from now on with `load` (a test holds it back
 * to type into the wait). Returns the undo, which puts the real chunk back as it was.
 */
export function holdPromptEditorForTests(load: () => Promise<PromptEditorModule>): () => void {
  const was = { editorModule, editorLoad, importEditor };
  editorModule = undefined;
  editorLoad = undefined;
  importEditor = load;
  return () => {
    ({ editorModule, editorLoad, importEditor } = was);
  };
}

/** How long an idle wait may last before the chunk is fetched anyway. */
const IDLE_TIMEOUT_MS = 500;

function whenIdle(): Promise<void> {
  return new Promise((resolve) => {
    if (typeof requestIdleCallback === "function") requestIdleCallback(() => resolve(), { timeout: IDLE_TIMEOUT_MS });
    else setTimeout(resolve, 0);
  });
}

const graphemes = intl.Segmenter(undefined, { granularity: "grapheme" });

/** `text`'s characters as a person counts them. */
function characters(text: string): string[] {
  return Array.from(graphemes.segment(text), (part) => part.segment);
}

const commandKey = (event: KeyboardEvent) => event.metaKey || event.ctrlKey || event.altKey;

/** A typed key the field keeps for the editor: one character, with no command modifier. */
function typedCharacter(event: KeyboardEvent): string | undefined {
  if (event.defaultPrevented || event.isComposing || commandKey(event)) return undefined;
  return characters(event.key).length === 1 ? event.key : undefined;
}

export const LazyPromptEditor = forwardRef<PromptEditorHandle, PromptEditorProps>(
  function LazyPromptEditor(props, ref) {
    const [module, setModule] = useState(editorModule);
    const real = useRef<PromptEditorHandle | null>(null);
    const frame = useRef<HTMLDivElement | null>(null);
    const latest = useRef(props);
    latest.current = props;
    /** The editor is made (PromptEditor's onReady): from then on the handle is the editor's own. */
    const ready = useRef(false);
    /** Focus was asked for (or the box took the keyboard) before the editor was made. */
    const wantsFocus = useRef(false);
    /** Text typed (or inserted through the handle) before the editor was made. */
    const typed = useRef("");
    /** Quotes taken before the editor was made. */
    const quotes = useRef<string[]>([]);
    const [listening, setListening] = useState(false);

    const fetchNow = useCallback(() => {
      if (editorModule) return;
      void loadPromptEditor().then(setModule, () => undefined);
    }, []);
    useEffect(() => {
      if (module) return;
      let live = true;
      void whenIdle()
        .then(loadPromptEditor)
        .then(
          (loaded) => live && setModule(() => loaded),
          () => undefined,
        );
      return () => {
        live = false;
      };
    }, [module]);

    /** The box took the keyboard (a press, a focus asked for, the page's own move): keep its keys. */
    const boxFocused = useCallback(() => {
      if (ready.current) return;
      wantsFocus.current = true;
      fetchNow();
      setListening(true);
    }, [fetchNow]);
    /** The keyboard went to another control or field: the editor does not take it back. */
    const boxBlurred = useCallback((event: FocusEvent<HTMLDivElement>) => {
      const next = event.relatedTarget;
      if (!next || event.currentTarget.contains(next)) return;
      wantsFocus.current = false;
      setListening(false);
    }, []);

    /** Focus asked for early: the box takes the keyboard now, the editor once it is made. */
    const askFocus = useCallback(() => {
      wantsFocus.current = true;
      fetchNow();
      if (real.current) focusRoute(real.current, "system", "the prompt field, asked for while its editor is made");
      else focusRoute(frame.current, "system", "the prompt field, asked for before its editor's chunk arrived");
    }, [fetchNow]);

    // Keys typed while the box has the keyboard, and after it gives way to the editor (the chunk is
    // here, the box is gone) while the editor is still being made: the keyboard is on the page then
    // only because the box it was in went away. A press anywhere else ends the wait.
    useEffect(() => {
      if (!listening) return;
      const keyDown = (event: KeyboardEvent) => {
        const active = document.activeElement;
        const box = frame.current;
        if (box ? !box.contains(active) : active && active !== document.body) return;
        const character = typedCharacter(event);
        if (character !== undefined) typed.current += character;
        else if (event.key === "Backspace" && typed.current && !commandKey(event))
          typed.current = characters(typed.current).slice(0, -1).join("");
        else return;
        event.preventDefault();
      };
      const pointerDown = (event: Event) => {
        const field = frame.current ?? real.current?.element();
        if (field && !field.contains(event.target as Node | null)) {
          wantsFocus.current = false;
          setListening(false);
        }
      };
      window.addEventListener("keydown", keyDown, true);
      window.addEventListener("pointerdown", pointerDown, true);
      return () => {
        window.removeEventListener("keydown", keyDown, true);
        window.removeEventListener("pointerdown", pointerDown, true);
      };
    }, [listening]);

    const onReady = useCallback(() => {
      ready.current = true;
      setListening(false);
      const editor = real.current;
      const text = typed.current;
      typed.current = "";
      if (editor && text) {
        focusRoute(editor, "system", "the prompt editor is made: the keys typed into its field before");
        editor.insertTyped(text);
      }
      latest.current.onReady?.();
    }, []);

    const attach = useCallback((handle: PromptEditorHandle | null) => {
      real.current = handle;
      if (!handle) return;
      if (wantsFocus.current) focusRoute(handle, "system", "the prompt editor is made: focus asked for before");
      for (const quote of quotes.current.splice(0)) handle.quoteReply(quote);
    }, []);

    useImperativeHandle(ref, () => {
      // Before the editor is made: what PromptEditor's handle answers then (nothing typed, the value
      // that came in), with focus, typing and quotes kept for the editor.
      const early: Partial<PromptEditorHandle> = {
        focus: askFocus,
        value: () => latest.current.value,
        plainText: () => latest.current.value,
        text: () => ({ value: latest.current.value, selectionStart: 0, selectionEnd: 0 }),
        caret: () => 0,
        focused: () => false,
        atStart: () => false,
        caretOnEdgeLine: () => true,
        history: () => ({ undo: false, redo: false, depth: 0, redoDepth: 0 }),
        formats: () => new Set(),
        element: () => frame.current,
        agentText: (markdown) => markdown,
        type: () => false,
        insertInline: () => false,
        insertCommand: () => false,
        inlineIds: () => undefined,
        insertTyped: (text) => {
          typed.current += text;
        },
        quoteReply: (markdown) => {
          quotes.current.push(markdown);
          askFocus();
          return true;
        },
      };
      return new Proxy({} as PromptEditorHandle, {
        get: (_, key: keyof PromptEditorHandle) => {
          const editor = real.current;
          // The editor's own handle once it is made; before that, its own for what it already
          // handles early (focus, quotes), with typing kept here.
          if (editor && (ready.current || (key !== "insertTyped" && key !== "focus"))) return editor[key];
          return early[key] ?? (() => undefined);
        },
      });
    }, [askFocus]);

    if (!module)
      return (
        <MarkdownFieldFrame
          className={props.className}
          placeholder={props.placeholder}
          placeholderKey={props.placeholderKey}
          frameRef={frame}
          onPointerDown={askFocus}
          waiting
          onFocus={boxFocused}
          onBlur={boxBlurred}
        />
      );
    const { PromptEditor } = module;
    return <PromptEditor {...props} ref={attach} onReady={onReady} />;
  },
);
