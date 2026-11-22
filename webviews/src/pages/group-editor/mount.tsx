// Boots the workspace group editor page: one page kept warm, shown in the native bubble for each
// open (GroupEditorService.swift draws the glass and sizes itself to the card). Each open arrives as
// a `cmux.groupEditor.session` event with a new id: the page resets the field to the name, focuses
// it and selects it all. A refresh (same id, new revision) updates the dots and rows, and the
// field only while the person has not typed in it. After every event is drawn the page answers
// `cmux.groupEditor.ready` with the card's height, so the bubble opens at once at its full size.
// main.tsx boots it; tests and the gallery mount it directly.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import type { PageClient } from "../shared/pageClient";
import { GroupEditorCard, type GroupEditorLayout } from "./GroupEditor";
import { GroupEditorOps, NO_SESSION, type GroupEditorSession } from "./host";

export interface MountedGroupEditor {
  /** Applies one session event (the host's stream calls this; tests and the gallery call it directly). */
  open(session: GroupEditorSession): void;
  /** The session drawn now. */
  readonly session: GroupEditorSession;
  /** Stops listening and removes the card (the gallery's stages). */
  unmount(): void;
}

export interface MountOptions {
  makeRoot?: typeof createRoot;
  /** The frame after the commit (tests pass their own). */
  nextFrame?: (run: () => void) => () => void;
  layout?: GroupEditorLayout;
}

function animationFrame(run: () => void): () => void {
  if (typeof requestAnimationFrame !== "function") {
    const timer = setTimeout(run, 0);
    return () => clearTimeout(timer);
  }
  const frame = requestAnimationFrame(run);
  return () => cancelAnimationFrame(frame);
}

export function mountGroupEditor(
  root: HTMLElement,
  client: PageClient | null,
  options: MountOptions = {},
): MountedGroupEditor {
  const reactRoot = (options.makeRoot ?? createRoot)(root);
  const nextFrame = options.nextFrame ?? animationFrame;
  let session: GroupEditorSession = NO_SESSION;
  /** The person typed in the field during this session: a refresh keeps their text. */
  let typed = false;
  /** The dot pressed since the last event, ringed before the host's refresh comes back. */
  let picked: string | undefined;
  let cancelReady: (() => void) | null = null;
  const name: { current: HTMLInputElement | null } = { current: null };
  const card: { current: HTMLDivElement | null } = { current: null };

  // Every call names the session it was made in, so the host drops one that outlived its open.
  const send = (op: string, id: string, params: Record<string, unknown> = {}) => {
    if (!id || !client) return;
    void client.call(op, { session: id, ...params }).catch((error: unknown) => {
      console.error(`group editor: ${op} failed`, error);
    });
  };

  const render = () => {
    const id = session.id;
    reactRoot.render(
      id ? (
        <GroupEditorCard
          key={id}
          session={session}
          picked={picked}
          layout={options.layout}
          nameRef={name}
          cardRef={card}
          onDraft={(text) => {
            if (id !== session.id) return;
            typed = true;
            send(GroupEditorOps.draft, id, { name: text });
          }}
          onColor={(color) => {
            if (id !== session.id) return;
            picked = color;
            flushSync(render);
            send(GroupEditorOps.color, id, { color });
          }}
          onCustomColor={() => send(GroupEditorOps.customColor, id)}
          onItem={(item) => send(GroupEditorOps.item, id, { item })}
          onClose={() => send(GroupEditorOps.close, id)}
        />
      ) : null,
    );
  };

  /** One ready per drawn revision, a frame after the commit; a newer event in that frame supersedes it. */
  const scheduleReady = () => {
    cancelReady?.();
    cancelReady = null;
    if (!session.id) return;
    const { id, revision } = session;
    cancelReady = nextFrame(() => {
      cancelReady = null;
      if (session.id !== id || session.revision !== revision || !card.current) return;
      const height = Math.ceil(card.current.getBoundingClientRect().height);
      send(GroupEditorOps.ready, id, { revision, height });
    });
  };

  const open = (next: GroupEditorSession) => {
    const isNew = next.id !== session.id;
    // An event older than the one drawn (a reordered refresh) changes nothing.
    if (!isNew && next.revision <= session.revision) return;
    session = next;
    picked = undefined;
    if (isNew) typed = next.draft != null;
    flushSync(render);
    const field = name.current;
    if (next.id && field) {
      if (isNew) {
        field.value = next.draft ?? next.name;
        field.focus();
        field.select();
      } else if (!typed && field.value !== next.name) {
        field.value = next.name;
      }
      document.title = next.strings.editor;
    }
    scheduleReady();
  };

  flushSync(render);
  let stopped = false;
  let unsubscribe: (() => void) | undefined;
  if (client)
    void client
      .subscribe<GroupEditorSession>(GroupEditorOps.session, (data) => {
        if (!stopped) open(data);
      })
      .then((stop) => (stopped ? stop() : (unsubscribe = stop)))
      .catch((error: unknown) => console.error("group editor: no session stream", error));
  return {
    open,
    get session() {
      return session;
    },
    unmount() {
      stopped = true;
      unsubscribe?.();
      cancelReady?.();
      reactRoot.unmount();
    },
  };
}
