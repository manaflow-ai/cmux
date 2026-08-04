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

type DiffEditingAction =
  | { type: "commit-edit-item"; itemId: string; fileDiff: NonNullable<DiffItem["fileDiff"]> }
  | { type: "restore-edit-items"; items: DiffItem[] }
  | { type: "set-edit-feedback"; message: string; error?: boolean }
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
  useUnsavedEditWarning(state.dirtyItemIds.length > 0);

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
    dispatch({ type: "set-edit-mode", enabled: true, editableItemIds });
  }, [dispatch, editableItemIds, editingReady, label, latestState]);

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
  }, [dispatch, label, latestState]);

  const discardEdits = useCallback(() => {
    const snapshot = snapshotRef.current;
    if (!snapshot) {
      return;
    }
    snapshotRef.current = null;
    baselineByItemRef.current.clear();
    draftByItemRef.current.clear();
    oldFileByItemRef.current.clear();
    dispatch({ type: "restore-edit-items", items: snapshot });
  }, [dispatch]);

  const onItemEditChange = useCallback((item: DiffItem, file: FileContents) => {
    draftByItemRef.current.set(item.id, file.contents);
    const baseline = baselineByItemRef.current.get(item.id);
    dispatch({
      type: "set-item-dirty",
      itemId: item.id,
      dirty: baseline == null || baseline !== file.contents,
    });
  }, [dispatch]);

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
    const itemById = new Map(latestState.current.items.map((item) => [item.id, item]));
    let failureMessage = "";
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
      const cacheKey = `cmux-edit-${session.sessionId}-${item.id}-v${version}`;
      let fileDiff: NonNullable<DiffItem["fileDiff"]>;
      try {
        fileDiff = {
          ...item.fileDiff,
          ...parseDiffFromFile(oldFileByItemRef.current.get(itemId) ?? null, {
            name: path,
            contents,
            cacheKey,
            lang: item.fileDiff.lang,
          }),
          cacheKey,
        };
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
        baselineByItemRef.current.set(itemId, contents);
        dispatch({ type: "commit-edit-item", itemId, fileDiff });
        dispatch({ type: "set-item-dirty", itemId, dirty: false });
        if (snapshotRef.current) {
          snapshotRef.current = snapshotRef.current.map((snapshotItem) => (
            snapshotItem.id === itemId
              ? { ...snapshotItem, fileDiff: cloneFileDiffMetadata(fileDiff), version }
              : snapshotItem
          ));
        }
      } catch (error) {
        if (error instanceof DiffTransportError && error.code === "editConflict") {
          hadConflict = true;
          failureMessage = label("editConflict");
        } else if (!hadConflict) {
          failureMessage = label("editSaveFailed");
        }
      }
    }
    dispatch({ type: "set-edit-saving", saving: false });
    if (failureMessage !== "") {
      dispatch({ type: "set-edit-feedback", message: failureMessage, error: true });
      return false;
    }
    snapshotRef.current = null;
    baselineByItemRef.current.clear();
    draftByItemRef.current.clear();
    oldFileByItemRef.current.clear();
    dispatch({ type: "set-edit-mode", enabled: false });
    dispatch({ type: "set-edit-feedback", message: label("editsSaved") });
    return true;
  }, [activeSessionRef, dispatch, label, latestState, transport]);

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
    saveEdits,
  };
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
