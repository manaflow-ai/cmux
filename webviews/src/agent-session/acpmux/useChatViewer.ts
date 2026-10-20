import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ViewedFile } from "./FileViewer";
import type { FilesSource } from "./FilesView";
import { readPathChip } from "./chips/host";

type Read = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/** The file and folder views share the chat's viewer slot and session lifetime. */
export function useChatViewer(sessionId: string | undefined, cwd: string | undefined, onOpen: () => void, read: Read) {
  const [fileView, setFileView] = useState<ViewedFile>();
  const [filesView, setFilesView] = useState<{ sessionId?: string; folder: string }>();
  const fileOpener = useRef<HTMLElement | undefined>(undefined);
  const filesOpener = useRef<HTMLElement | undefined>(undefined);
  const restore = useRef<HTMLElement | undefined>(undefined);
  const session = useRef(sessionId);
  const generation = useRef(0);
  const fileRequest = useRef(0);
  if (session.current !== sessionId) {
    session.current = sessionId;
    fileOpener.current = undefined;
    filesOpener.current = undefined;
    restore.current = undefined;
    generation.current += 1;
  }
  const invalidate = useCallback(() => {
    generation.current += 1;
  }, []);
  useEffect(() => invalidate, [invalidate]);
  const opened = useRef(onOpen);
  opened.current = onOpen;
  const viewFile = useCallback((path: string, opener?: HTMLElement): Promise<void> => {
    const clicked = opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined);
    const initiatingSession = session.current;
    const started = generation.current;
    const request = ++fileRequest.current;
    const current = () =>
      session.current === initiatingSession && generation.current === started && fileRequest.current === request;
    return readPathChip(path)
      .then((reply) => {
        if (!current()) return;
        const value = reply as (ViewedFile & { kind?: string }) | undefined;
        if (value?.kind !== "text" || typeof value.path !== "string" || typeof value.text !== "string") return;
        // Files stays current while a read is pending or opens outside the viewer. Only a
        // successful text read replaces it and invalidates its pending listing/search.
        generation.current += 1;
        fileOpener.current = clicked;
        opened.current();
        setFileView({
          path: value.path,
          text: value.text,
          bytes: typeof value.bytes === "number" ? value.bytes : value.text.length,
          truncated: value.truncated === true,
          sessionId: initiatingSession,
        });
      })
      .catch((error: unknown) => {
        if (current()) throw error;
      });
  }, []);
  const fileOpen = fileView !== undefined && fileView.sessionId === sessionId;
  const filesOpen = filesView !== undefined && filesView.sessionId === sessionId;
  useEffect(() => {
    if (fileView && !fileOpen) setFileView(undefined);
    if (filesView && !filesOpen) setFilesView(undefined);
  }, [fileView, fileOpen, filesView, filesOpen]);
  useLayoutEffect(() => {
    if (fileView || filesView || !restore.current) return;
    restore.current.focus({ preventScroll: true });
    restore.current = undefined;
  }, [fileView, filesView]);
  const closeFile = useCallback(() => {
    invalidate();
    restore.current = fileOpener.current;
    setFileView(undefined);
  }, [invalidate]);
  const closeFiles = useCallback(() => {
    invalidate();
    restore.current = filesOpener.current;
    setFileView(undefined);
    setFilesView(undefined);
  }, [invalidate]);
  const openFiles = (folder: string, opener?: HTMLElement) => {
    filesOpener.current =
      opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined);
    restore.current = undefined;
    invalidate();
    opened.current();
    setFileView(undefined);
    setFilesView({ sessionId: session.current, folder });
  };
  // An in-place diff replaces files, but keeps production Thread details and inspector behavior.
  const openChanges = (open: () => void) => {
    restore.current = undefined;
    invalidate();
    setFileView(undefined);
    setFilesView(undefined);
    open();
  };
  const filesSource = useMemo<FilesSource>(() => {
    const request = async <T>(method: string, params: Record<string, unknown>): Promise<T | undefined> => {
      const initiatingSession = sessionId;
      const started = generation.current;
      const current = () => session.current === initiatingSession && generation.current === started;
      try {
        const reply = await read(method, params);
        return current() ? (reply as T) : undefined;
      } catch (error) {
        if (current()) throw error;
        return undefined;
      }
    };
    return {
      list: (folder) =>
        request<Awaited<ReturnType<FilesSource["list"]>>>("file.list", { cwd: cwd ?? "", path: folder }),
      search: (query) =>
        request<Awaited<ReturnType<FilesSource["search"]>>>("file.search", { cwd: cwd ?? "", query, limit: 100 }),
    };
  }, [cwd, read, sessionId]);
  return {
    invalidate,
    fileView,
    filesView,
    fileOpen,
    filesOpen,
    viewFile,
    closeFile,
    closeFiles,
    openFiles,
    openChanges,
    setFileView,
    setFilesView,
    filesSource,
  };
}
