// The markdown page's empty state: no file yet. The user picks a recent file, chooses one (the
// host's picker) or drops one; `open` (MarkdownStore.openFile, `cmux.markdown.open`) loads it.
import { useRef, useState } from "react";
import { isPageError, type PageClient } from "../pages/shared/pageClient";
import type { Strings } from "../pages/shared/i18n";
import type { DroppedItem } from "./drop";
import { EmptyState, RecentList } from "./EmptyState";
import {
  MARKDOWN_CHOOSE_FILE_OP,
  MARKDOWN_NOT_MARKDOWN,
  MARKDOWN_RECENTS_OP,
  baseName,
  isMarkdownName,
  parseChosenPath,
  parseRecents,
  type RecentItem,
} from "./ops";
import { parentPath } from "./pickerModel";
import { E } from "./strings";

export interface MarkdownEmptyStateProps {
  client: PageClient;
  strings: Strings;
  /** Opens the file; rejects with the host's error. */
  open(path: string): Promise<void>;
  now?: number;
}

export function MarkdownEmptyState({ client, strings, open, now }: MarkdownEmptyStateProps) {
  const { t } = strings;
  const [recents, setRecents] = useState<RecentItem[] | null>(null);
  const [home, setHome] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const loaded = useRef(false);
  const mountRef = (element: HTMLDivElement | null) => {
    if (!element || loaded.current) return;
    loaded.current = true;
    void client
      .call<unknown>(MARKDOWN_RECENTS_OP, {})
      .then((value) => {
        setRecents(parseRecents(value));
        const reported = (value as { home?: unknown } | null)?.home;
        setHome(typeof reported === "string" ? reported : null);
      })
      .catch(() => setRecents([]));
  };

  const openPath = async (path: string) => {
    setError(null);
    if (!isMarkdownName(path)) return setError(strings.format(E.errorNotMarkdown, baseName(path)));
    try {
      await open(path);
    } catch (failure) {
      setError(
        isPageError(failure) && failure.code === MARKDOWN_NOT_MARKDOWN
          ? strings.format(E.errorNotMarkdown, baseName(path))
          : strings.format(E.errorOpen, baseName(path)),
      );
    }
  };
  const chooseFile = async () => {
    setError(null);
    const start = recents?.[0] ? parentPath(recents[0].path) : undefined;
    let value: unknown;
    try {
      value = await client.call<unknown>(MARKDOWN_CHOOSE_FILE_OP, start ? { start } : {});
    } catch (failure) {
      console.warn("cmux markdown chooseFile failed", failure);
      return;
    }
    const path = parseChosenPath(value);
    if (path) void openPath(path);
  };
  const onDrop = (item: DroppedItem) => {
    if (!isMarkdownName(item.name)) return setError(strings.format(E.errorNotMarkdown, item.name));
    if (item.path) void openPath(item.path);
    else setError(strings.format(E.errorOpen, item.name));
  };

  return (
    <div ref={mountRef} className="ve-root">
      <EmptyState
        kind="markdown"
        title={t(E.markdownTitle)}
        subtitle={t(E.markdownSubtitle)}
        dropText={t(E.dropFile)}
        onDrop={onDrop}
        error={error}
      >
        <div className="ve-actions">
          <button
            type="button"
            className="ve-button ve-button-primary ve-button-large"
            onClick={() => void chooseFile()}
          >
            {t(E.markdownChoose)}
          </button>
        </div>
        <RecentList
          items={recents}
          home={home}
          icon="file"
          strings={strings}
          label={t(E.recentFilesLabel)}
          emptyText={t(E.recentFilesEmpty)}
          now={now}
          onOpen={(item) => void openPath(item.path)}
        />
      </EmptyState>
    </div>
  );
}
