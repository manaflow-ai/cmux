// The code editor's empty state: no file yet. The same layout and ops as the markdown page's
// (MarkdownEmptyState.tsx), for any file: a recent file, the host's picker (`cmux.editor.chooseFile`)
// or a drop; `open` (EditorStore.openFile, `cmux.editor.open`) loads it.
import { useRef, useState } from "react";
import type { PageClient } from "../pages/shared/pageClient";
import type { Strings } from "../pages/shared/i18n";
import type { DroppedItem } from "./drop";
import { EmptyState, RecentList } from "./EmptyState";
import {
  EDITOR_CHOOSE_FILE_OP,
  EDITOR_RECENTS_OP,
  baseName,
  parseChosenPath,
  parseRecents,
  type RecentItem,
} from "./ops";
import { parentPath } from "./pickerModel";
import { E } from "./strings";

/** The editor's own texts (its string table, pages/editor/strings.ts `EMPTY`). */
export interface EditorEmptyTexts {
  title: string;
  subtitle: string;
  choose: string;
  drop: string;
  recentsEmpty: string;
}

export interface EditorEmptyStateProps {
  client: PageClient;
  /** The shared empty-state strings (recent list, errors). */
  strings: Strings;
  texts: EditorEmptyTexts;
  /** Opens the file; rejects with the host's error. */
  open(path: string): Promise<void>;
  now?: number;
}

export function EditorEmptyState({ client, strings, texts, open, now }: EditorEmptyStateProps) {
  const { t } = strings;
  const [recents, setRecents] = useState<RecentItem[] | null>(null);
  const [home, setHome] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const loaded = useRef(false);
  const mountRef = (element: HTMLDivElement | null) => {
    if (!element || loaded.current) return;
    loaded.current = true;
    void client
      .call<unknown>(EDITOR_RECENTS_OP, {})
      .then((value) => {
        setRecents(parseRecents(value));
        const reported = (value as { home?: unknown } | null)?.home;
        setHome(typeof reported === "string" ? reported : null);
      })
      .catch(() => setRecents([]));
  };

  const openPath = async (path: string) => {
    setError(null);
    try {
      await open(path);
    } catch {
      setError(strings.format(E.errorOpen, baseName(path)));
    }
  };
  const chooseFile = async () => {
    setError(null);
    const start = recents?.[0] ? parentPath(recents[0].path) : undefined;
    let value: unknown;
    try {
      value = await client.call<unknown>(EDITOR_CHOOSE_FILE_OP, start ? { start } : {});
    } catch (failure) {
      console.warn("cmux editor chooseFile failed", failure);
      return;
    }
    const path = parseChosenPath(value);
    if (path) void openPath(path);
  };
  const onDrop = (item: DroppedItem) => {
    if (item.path) void openPath(item.path);
    else setError(strings.format(E.errorOpen, item.name));
  };

  return (
    <div ref={mountRef} className="ve-root">
      <EmptyState
        kind="editor"
        title={texts.title}
        subtitle={texts.subtitle}
        dropText={texts.drop}
        onDrop={onDrop}
        error={error}
      >
        <div className="ve-actions">
          <button
            type="button"
            className="ve-button ve-button-primary ve-button-large"
            onClick={() => void chooseFile()}
          >
            {texts.choose}
          </button>
        </div>
        <RecentList
          items={recents}
          home={home}
          icon="file"
          strings={strings}
          label={t(E.recentFilesLabel)}
          emptyText={texts.recentsEmpty}
          now={now}
          onOpen={(item) => void openPath(item.path)}
        />
      </EmptyState>
    </div>
  );
}
