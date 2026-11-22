// PromptEditor (Milkdown, about half a megabyte of script) as its own chunk, for a page whose
// startup should not wait on it (Home Channels' composer). Until the chunk arrives it draws the
// field's own pre-editor box (markdownFieldFrame.tsx), the one PromptEditor draws until its editor
// is made: the same box, placeholder and height from the first frame, so nothing moves when the
// editor takes over. The chunk is fetched once the page is idle after its first frame, or at once
// when the field is pressed or asked for focus.
//
// The handle works from the start: focus asked for early is applied once the editor is made (as
// PromptEditor's own does), and the keys typed into the field before then (a press on it, or a
// focus asked for, then typing) are kept and typed into the editor when it is ready, so no
// keystroke is lost.
import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from "react";
import { lazyChunk } from "../../../lazyChunk";
import { focusRoute } from "../../../ui/focusRoute";
import { intl } from "../../../ui/intl";
import { MarkdownFieldFrame } from "../markdownFieldFrame";
import type { PromptEditorHandle, PromptEditorProps } from "./PromptEditor";

type PromptEditorModule = typeof import("./PromptEditor");
let editorModule: PromptEditorModule | undefined;
let editorLoad: Promise<PromptEditorModule> | undefined;

/** Fetches PromptEditor's chunk once; resolves to it. */
export const loadPromptEditor = lazyChunk((): Promise<PromptEditorModule> => {
  editorLoad ??= import("./PromptEditor").then(
    (module) => (editorModule = module),
    (error: unknown) => {
      // A failed fetch (a web update swapped the files) is tried again on the next ask.
      editorLoad = undefined;
      throw error;
    },
  );
  return editorLoad;
});

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

/** A typed key the field keeps for the editor: one character, with no command modifier. */
function typedCharacter(event: KeyboardEvent): string | undefined {
  if (event.defaultPrevented || event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return undefined;
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
    /** Focus was asked for (or the field pressed) before the editor was made. */
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

    /** Focus asked for early: kept, and the keys typed until the editor is made are kept with it. */
    const askFocus = useCallback(() => {
      wantsFocus.current = true;
      focusRoute(real.current, "system", "the prompt field was asked for before its editor was made");
      fetchNow();
      setListening(true);
    }, [fetchNow]);

    // Keys typed while the field waits for its editor. Only while nothing else has focus: a press on
    // another control or a field ends the wait.
    useEffect(() => {
      if (!listening) return;
      const field = () => real.current?.element() ?? frame.current;
      const keyDown = (event: KeyboardEvent) => {
        const active = document.activeElement;
        if (active && active !== document.body && !field()?.contains(active)) return stop();
        const character = typedCharacter(event);
        if (character !== undefined) typed.current += character;
        else if (event.key === "Backspace" && typed.current && !event.metaKey && !event.ctrlKey && !event.altKey)
          typed.current = characters(typed.current).slice(0, -1).join("");
        else return;
        event.preventDefault();
      };
      const pointerDown = (event: PointerEvent) => {
        if (!field()?.contains(event.target as Node | null)) stop();
      };
      const stop = () => {
        wantsFocus.current = false;
        setListening(false);
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
        />
      );
    const { PromptEditor } = module;
    return <PromptEditor {...props} ref={attach} onReady={onReady} />;
  },
);
