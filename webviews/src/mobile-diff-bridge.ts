import type { FileTreeSource } from "./diff-stream";
import { useEffect, useRef } from "react";

export type MobileDiffFile = {
  added: number;
  deleted: number;
  id: string;
  path: string;
};

export type MobileDiffFilesMessage = {
  files: MobileDiffFile[];
  generation: number | null;
  type: "files";
};

export type MobileDiffSelectionMessage = {
  generation: number | null;
  selectedItemId: string;
  type: "selection";
};

type MobileDiffMessageHandler = {
  postMessage(message: unknown): void;
};

type MobileDiffBridgeWindow = Window & {
  __cmuxMobileDiff?: {
    selectFile(itemId: string): void;
  };
  webkit?: {
    messageHandlers?: {
      cmuxMobileDiff?: MobileDiffMessageHandler;
    };
  };
};

export function mobileDiffFiles(source: FileTreeSource | null): MobileDiffFile[] {
  if (!source) {
    return [];
  }
  return source.paths.flatMap((path) => {
    const id = source.pathToItemId.get(path);
    if (!id) {
      return [];
    }
    const stats = source.statsByPath.get(path);
    return [{
      added: stats?.added ?? 0,
      deleted: stats?.deleted ?? 0,
      id,
      path,
    }];
  });
}

export function mobileDiffMessage(
  source: FileTreeSource | null,
  generation: number | null,
): MobileDiffFilesMessage {
  return {
    type: "files",
    files: mobileDiffFiles(source),
    generation,
  };
}

export function mobileDiffSelectionMessage(
  selectedItemId: string,
  generation: number | null,
): MobileDiffSelectionMessage {
  return { type: "selection", generation, selectedItemId };
}

export function mobileDiffCompletionMessages(
  source: FileTreeSource | null,
  selectedItemId: string,
  generation: number,
): [MobileDiffFilesMessage, MobileDiffSelectionMessage] {
  return [
    mobileDiffMessage(source, generation),
    mobileDiffSelectionMessage(selectedItemId, generation),
  ];
}

export function installMobileDiffBridge(
  generation: number | null,
  selectFile: (itemId: string) => void,
): () => void {
  const bridgeWindow = window as MobileDiffBridgeWindow;
  const messageHandler = bridgeWindow.webkit?.messageHandlers?.cmuxMobileDiff;
  if (generation === null || !messageHandler) {
    return () => {};
  }
  const bridge = { selectFile };
  bridgeWindow.__cmuxMobileDiff = bridge;
  return () => {
    if (bridgeWindow.__cmuxMobileDiff === bridge) {
      delete bridgeWindow.__cmuxMobileDiff;
    }
  };
}

export function useMobileDiffBridge(
  source: FileTreeSource | null,
  selectedItemId: string,
  generation: number | null,
  streamComplete: boolean,
  selectFile: (itemId: string) => void,
): void {
  const selectedItemIdRef = useRef(selectedItemId);
  selectedItemIdRef.current = selectedItemId;
  useEffect(
    () => installMobileDiffBridge(generation, selectFile),
    [generation, selectFile],
  );
  useEffect(() => {
    const messageHandler = (window as MobileDiffBridgeWindow).webkit?.messageHandlers?.cmuxMobileDiff;
    if (generation !== null && streamComplete && messageHandler) {
      for (const message of mobileDiffCompletionMessages(source, selectedItemIdRef.current, generation)) {
        messageHandler.postMessage(message);
      }
    }
  }, [source, generation, streamComplete]);
  useEffect(() => {
    const messageHandler = (window as MobileDiffBridgeWindow).webkit?.messageHandlers?.cmuxMobileDiff;
    if (generation !== null && messageHandler) {
      messageHandler.postMessage(mobileDiffSelectionMessage(selectedItemId, generation));
    }
  }, [selectedItemId, generation]);
}
