import { cloneFileDiffMetadata, parseDiffFromFile, type FileContents } from "@pierre/diffs";
import { Editor, type EditorOptions } from "@pierre/diffs/edit";
import { useCallback, useEffect, useMemo, useRef, type MutableRefObject } from "react";
import type { CommentAnnotationMetadata } from "./comments/types";
import { DiffTransportError, type DiffTransport } from "./diff/transport";
import type { DiffSource } from "./diff/generated/protocol";
import { fileName, type DiffItem } from "./diff-stream";
import type { DiffViewerLabelResolver } from "./labels";

export type ActiveDiffSession = {
  capabilityToken: string;
  sessionId: string;
};

type DiffEditingState = {
  dirtyItemIds: string[];
  editMode: boolean;
  editSaving: boolean;
  items: DiffItem[];
};

export type EditFeedbackRecovery = "none" | "retry" | "conflict";

export type EditSaveConflict = {
  diskContents: string;
  draftContents: string;
  itemId: string;
  path: string;
};

type DiffEditingAction =
  | { type: "commit-edit-item"; itemId: string; fileDiff: NonNullable<DiffItem["fileDiff"]> }
  | { type: "restore-edit-items"; items: DiffItem[] }
  | { type: "set-edit-conflict"; conflict: EditSaveConflict | null }
  | { type: "set-edit-feedback"; message: string; error?: boolean; recovery?: EditFeedbackRecovery }
  | { type: "set-edit-mode"; enabled: boolean; editableItemIds?: string[] }
  | { type: "set-edit-saving"; saving: boolean }
  | { type: "set-item-dirty"; itemId: string; dirty: boolean };

type UseDiffEditingOptions = {
  activeSession: ActiveDiffSession | null;
  activeSessionRef: MutableRefObject<ActiveDiffSession | null>;
  diffStreamComplete: boolean;
  dispatch: (action: DiffEditingAction) => void;
  label: DiffViewerLabelResolver;
  latestState: MutableRefObject<DiffEditingState>;
  sessionSource: DiffSource | null;
  state: DiffEditingState;
  transport: DiffTransport | null;
};

export function createPierreEditor<LAnnotation>(options: EditorOptions<LAnnotation>): Editor<LAnnotation> {
  return new Editor(options);
}

export function isEditableSessionSource(source: DiffSource | null): boolean {
  return source?.kind === "unstaged" || source?.kind === "branch";
}

export function useDiffEditing({
  activeSession,
  activeSessionRef,
  diffStreamComplete,
  dispatch,
  label,
  latestState,
  sessionSource,
  state,
  transport,
}: UseDiffEditingOptions) {
  const baselineByItemRef = useRef(new Map<string, string>());
  const draftByItemRef = useRef(new Map<string, string>());
  const oldFileByItemRef = useRef(new Map<string, FileContents | null>());
  const snapshotRef = useRef<DiffItem[] | null>(null);
  const saveConflictRef = useRef<EditSaveConflict | null>(null);
  useUnsavedEditWarning(state.dirtyItemIds.length > 0);

  const setSaveConflict = useCallback((conflict: EditSaveConflict | null) => {
    saveConflictRef.current = conflict;
    dispatch({ type: "set-edit-conflict", conflict });
  }, [dispatch]);

  const editableItemIds = useMemo(() => {
    const ids: string[] = [];
    for (const item of state.items) {
      if (isEditableDiffItem(item)) {
        ids.push(item.id);
      }
    }
    return ids;
  }, [state.items]);
  const editingReady = activeSession != null
    && isEditableSessionSource(sessionSource)
    && diffStreamComplete
    && editableItemIds.length > 0;

  const onEditorAttach = useCallback((editor: Editor<CommentAnnotationMetadata>) => {
    const file = editor.getFile();
    if (!file) {
      return;
    }
    const item = latestState.current.items.find((candidate) => fileName(candidate.fileDiff, "") === file.name);
    if (item && !baselineByItemRef.current.has(item.id)) {
      baselineByItemRef.current.set(item.id, file.contents);
      draftByItemRef.current.set(item.id, file.contents);
    }
  }, [latestState]);
  const editorOptions = useMemo<EditorOptions<CommentAnnotationMetadata>>(() => ({
    historyMaxEntries: 200,
    onAttach: onEditorAttach,
    persistState: true,
  }), [onEditorAttach]);

  const loadDiffFiles = useCallback(async (fileDiff: any) => {
    const session = activeSessionRef.current;
    const path = fileName(fileDiff, "");
    if (!transport || !session || path === "") {
      throw new DiffTransportError("notEditable", "Diff editing is unavailable");
    }
    try {
      const result = await transport.request({
        method: "sessionFileLoad",
        params: { ...session, path },
      });
      if (result.type !== "sessionFileLoaded") {
        throw new DiffTransportError("invalidResponse", "Diff transport did not load the file");
      }
      const cachePrefix = `cmux-edit-${session.sessionId}-${result.value.path}`;
      const newFile: FileContents = {
        name: result.value.path,
        contents: result.value.newContents,
        cacheKey: `${cachePrefix}-new`,
        lang: fileDiff.lang,
      };
      const oldFile: FileContents | null = result.value.oldContents == null || fileDiff.type === "rename-pure"
        ? null
        : {
            name: result.value.previousPath ?? result.value.path,
            contents: result.value.oldContents,
            cacheKey: `${cachePrefix}-old`,
            lang: fileDiff.lang,
          };
      const item = latestState.current.items.find((candidate) => (
        candidate.fileDiff === fileDiff || fileName(candidate.fileDiff, "") === result.value.path
      ));
      if (item) {
        baselineByItemRef.current.set(item.id, result.value.newContents);
        draftByItemRef.current.set(item.id, result.value.newContents);
        oldFileByItemRef.current.set(item.id, oldFile);
      }
      return { oldFile, newFile };
    } catch (error) {
      dispatch({ type: "set-edit-feedback", message: label("editLoadFailed"), error: true });
      throw error;
    }
  }, [activeSessionRef, dispatch, label, latestState, transport]);

  const beginEditing = useCallback(() => {
    if (!editingReady) {
      dispatch({ type: "set-edit-feedback", message: label("editingUnavailable"), error: true });
      return;
    }
    snapshotRef.current = latestState.current.items.map(cloneDiffItem);
    baselineByItemRef.current.clear();
    draftByItemRef.current.clear();
    oldFileByItemRef.current.clear();
    setSaveConflict(null);
    dispatch({ type: "set-edit-mode", enabled: true, editableItemIds });
  }, [dispatch, editableItemIds, editingReady, label, latestState, setSaveConflict]);

  const endEditing = useCallback(() => {
    if (latestState.current.dirtyItemIds.length > 0) {
      dispatch({ type: "set-edit-feedback", message: label("saveOrDiscardEdits"), error: true });
      return;
    }
    dispatch({ type: "set-edit-mode", enabled: false });
    snapshotRef.current = null;
    baselineByItemRef.current.clear();
    draftByItemRef.current.clear();
    oldFileByItemRef.current.clear();
    setSaveConflict(null);
  }, [dispatch, label, latestState, setSaveConflict]);

  const discardEdits = useCallback(() => {
    const snapshot = snapshotRef.current;
    if (!snapshot) {
      return;
    }
    snapshotRef.current = null;
    baselineByItemRef.current.clear();
    draftByItemRef.current.clear();
    oldFileByItemRef.current.clear();
    setSaveConflict(null);
    dispatch({ type: "restore-edit-items", items: snapshot });
  }, [dispatch, setSaveConflict]);

  const onItemEditChange = useCallback((item: DiffItem, file: FileContents) => {
    draftByItemRef.current.set(item.id, file.contents);
    const baseline = baselineByItemRef.current.get(item.id);
    const dirty = baseline == null || baseline !== file.contents;
    const conflict = saveConflictRef.current;
    if (conflict?.itemId === item.id) {
      setSaveConflict(dirty ? { ...conflict, draftContents: file.contents } : null);
    }
    if (!dirty) {
      dispatch({ type: "set-edit-feedback", message: "" });
    }
    dispatch({
      type: "set-item-dirty",
      itemId: item.id,
      dirty,
    });
  }, [dispatch, setSaveConflict]);

  const captureSaveConflict = useCallback(async (
    session: ActiveDiffSession,
    itemId: string,
    path: string,
    draftContents: string,
  ) => {
    if (!transport) {
      return false;
    }
    try {
      const result = await transport.request({
        method: "sessionFileLoad",
        params: { ...session, path },
      });
      if (result.type !== "sessionFileLoaded") {
        return false;
      }
      setSaveConflict({
        diskContents: result.value.newContents,
        draftContents,
        itemId,
        path: result.value.path,
      });
      return true;
    } catch {
      return false;
    }
  }, [setSaveConflict, transport]);

  const commitSavedItem = useCallback((
    item: DiffItem,
    contents: string,
    fileDiff: NonNullable<DiffItem["fileDiff"]>,
    version: number,
  ) => {
    baselineByItemRef.current.set(item.id, contents);
    dispatch({ type: "commit-edit-item", itemId: item.id, fileDiff });
    dispatch({ type: "set-item-dirty", itemId: item.id, dirty: false });
    if (snapshotRef.current) {
      snapshotRef.current = snapshotRef.current.map((snapshotItem) => (
        snapshotItem.id === item.id
          ? { ...snapshotItem, fileDiff: cloneFileDiffMetadata(fileDiff), version }
          : snapshotItem
      ));
    }
  }, [dispatch]);

  const finishSaving = useCallback(() => {
    snapshotRef.current = null;
    baselineByItemRef.current.clear();
    draftByItemRef.current.clear();
    oldFileByItemRef.current.clear();
    setSaveConflict(null);
    dispatch({ type: "set-edit-mode", enabled: false });
    dispatch({ type: "set-edit-feedback", message: label("editsSaved") });
    return true;
  }, [dispatch, label, setSaveConflict]);

  const saveEdits = useCallback(async () => {
    const session = activeSessionRef.current;
    if (!transport || !session || latestState.current.editSaving) {
      return false;
    }
    const dirtyIds = [...latestState.current.dirtyItemIds];
    if (dirtyIds.length === 0) {
      return false;
    }
    dispatch({ type: "set-edit-saving", saving: true });
    dispatch({ type: "set-edit-feedback", message: "" });
    setSaveConflict(null);
    const itemById = new Map(latestState.current.items.map((item) => [item.id, item]));
    let failureMessage = "";
    let failureRecovery: EditFeedbackRecovery = "retry";
    let hadConflict = false;
    // Each save can carry two 1 MiB file snapshots. Keep requests serial so a
    // large multi-file edit cannot retain every JSON body or saturate the
    // native sidecar process pool at once.
    for (const itemId of dirtyIds) {
      const item = itemById.get(itemId);
      const expectedContents = baselineByItemRef.current.get(itemId);
      const contents = draftByItemRef.current.get(itemId);
      const path = item ? fileName(item.fileDiff, "") : "";
      if (!item || expectedContents == null || contents == null || path === "" || !oldFileByItemRef.current.has(itemId)) {
        failureMessage ||= label("editSaveFailed");
        continue;
      }
      const version = (item.version ?? 0) + 1;
      let fileDiff: NonNullable<DiffItem["fileDiff"]>;
      try {
        fileDiff = editedFileDiff(session.sessionId, item, path, contents, oldFileByItemRef.current.get(itemId) ?? null, version);
      } catch {
        failureMessage ||= label("editSaveFailed");
        continue;
      }
      try {
        const result = await transport.request({
          method: "sessionFileSave",
          params: { ...session, path, expectedContents, contents },
        });
        if (result.type !== "sessionFileSaved") {
          throw new DiffTransportError("invalidResponse", "Diff transport did not save the file");
        }
        commitSavedItem(item, contents, fileDiff, version);
      } catch (error) {
        if (hasDiffTransportErrorCode(error, "editConflict")
          && await captureSaveConflict(session, itemId, path, contents)) {
          hadConflict = true;
          failureRecovery = "conflict";
          failureMessage = label("editConflict").replace("{path}", path);
        } else if (!hadConflict) {
          failureMessage = label("editSaveFailed");
          failureRecovery = "retry";
        }
      }
    }
    dispatch({ type: "set-edit-saving", saving: false });
    if (failureMessage !== "") {
      dispatch({ type: "set-edit-feedback", message: failureMessage, error: true, recovery: failureRecovery });
      return false;
    }
    return finishSaving();
  }, [activeSessionRef, captureSaveConflict, commitSavedItem, dispatch, finishSaving, label, latestState, setSaveConflict, transport]);

  const overwriteConflict = useCallback(async () => {
    const session = activeSessionRef.current;
    const conflict = saveConflictRef.current;
    if (!transport || !session || !conflict || latestState.current.editSaving) {
      return false;
    }
    const item = latestState.current.items.find((candidate) => candidate.id === conflict.itemId);
    const contents = draftByItemRef.current.get(conflict.itemId) ?? conflict.draftContents;
    if (!item || !item.fileDiff || !oldFileByItemRef.current.has(conflict.itemId)) {
      dispatch({ type: "set-edit-feedback", message: label("editSaveFailed"), error: true, recovery: "retry" });
      return false;
    }
    const version = (item.version ?? 0) + 1;
    let fileDiff: NonNullable<DiffItem["fileDiff"]>;
    try {
      fileDiff = editedFileDiff(
        session.sessionId,
        item,
        conflict.path,
        contents,
        oldFileByItemRef.current.get(conflict.itemId) ?? null,
        version,
      );
    } catch {
      dispatch({ type: "set-edit-feedback", message: label("editSaveFailed"), error: true, recovery: "retry" });
      return false;
    }

    dispatch({ type: "set-edit-saving", saving: true });
    dispatch({ type: "set-edit-feedback", message: "" });
    try {
      const result = await transport.request({
        method: "sessionFileSave",
        params: {
          ...session,
          path: conflict.path,
          expectedContents: conflict.diskContents,
          contents,
        },
      });
      if (result.type !== "sessionFileSaved") {
        throw new DiffTransportError("invalidResponse", "Diff transport did not save the file");
      }
      commitSavedItem(item, contents, fileDiff, version);
      setSaveConflict(null);
      dispatch({ type: "set-edit-saving", saving: false });
      const remainingDirtyIds = latestState.current.dirtyItemIds.filter((itemId) => itemId !== conflict.itemId);
      if (remainingDirtyIds.length === 0) {
        return finishSaving();
      }
      dispatch({
        type: "set-edit-feedback",
        message: label("editFileSaved").replace("{path}", conflict.path),
        recovery: "retry",
      });
      return false;
    } catch (error) {
      if (hasDiffTransportErrorCode(error, "editConflict")
        && await captureSaveConflict(session, conflict.itemId, conflict.path, contents)) {
        dispatch({
          type: "set-edit-feedback",
          message: label("editConflict").replace("{path}", conflict.path),
          error: true,
          recovery: "conflict",
        });
      } else {
        dispatch({
          type: "set-edit-feedback",
          message: label("editOverwriteFailed").replace("{path}", conflict.path),
          error: true,
          recovery: "conflict",
        });
      }
      dispatch({ type: "set-edit-saving", saving: false });
      return false;
    }
  }, [activeSessionRef, captureSaveConflict, commitSavedItem, dispatch, finishSaving, label, latestState, setSaveConflict, transport]);

  const blockForUnsavedEdits = useCallback(() => {
    if (latestState.current.dirtyItemIds.length === 0) {
      return false;
    }
    dispatch({ type: "set-edit-feedback", message: label("saveOrDiscardEdits"), error: true });
    return true;
  }, [dispatch, label, latestState]);

  return {
    beginEditing,
    blockForUnsavedEdits,
    discardEdits,
    editingReady,
    editorOptions,
    endEditing,
    loadDiffFiles,
    onItemEditChange,
    overwriteConflict,
    saveEdits,
  };
}

function editedFileDiff(
  sessionId: string,
  item: DiffItem,
  path: string,
  contents: string,
  oldFile: FileContents | null,
  version: number,
): NonNullable<DiffItem["fileDiff"]> {
  if (!item.fileDiff) {
    throw new Error("Missing file diff");
  }
  const cacheKey = `cmux-edit-${sessionId}-${item.id}-v${version}`;
  return {
    ...item.fileDiff,
    ...parseDiffFromFile(oldFile, {
      name: path,
      contents,
      cacheKey,
      lang: item.fileDiff.lang,
    }),
    cacheKey,
  };
}

export function hasDiffTransportErrorCode(error: unknown, code: string): boolean {
  if (error instanceof DiffTransportError) {
    return error.code === code;
  }
  if (typeof error !== "object" || error == null) {
    return false;
  }
  const candidate = error as { code?: unknown; error?: { code?: unknown } };
  return candidate.code === code || candidate.error?.code === code;
}

function cloneDiffItem(item: DiffItem): DiffItem {
  return {
    ...item,
    fileDiff: item.fileDiff ? cloneFileDiffMetadata(item.fileDiff) : item.fileDiff,
  };
}

function isEditableDiffItem(item: DiffItem): boolean {
  return item.fileDiff != null
    && item.fileDiff.type !== "deleted"
    && item.fileDiff.cmuxDiffMetadataKind !== "binary";
}

function useUnsavedEditWarning(hasUnsavedEdits: boolean): void {
  useEffect(() => {
    if (!hasUnsavedEdits) {
      return;
    }
    const warnBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warnBeforeUnload);
    return () => window.removeEventListener("beforeunload", warnBeforeUnload);
  }, [hasUnsavedEdits]);
}
