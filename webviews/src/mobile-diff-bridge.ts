import type { FileTreeSource } from "./diff-stream";
import { useEffect } from "react";

export type MobileDiffFile = {
  added: number;
  deleted: number;
  id: string;
  path: string;
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

export function installMobileDiffBridge(
  source: FileTreeSource | null,
  selectedItemId: string,
  selectFile: (itemId: string) => void,
): () => void {
  const bridgeWindow = window as MobileDiffBridgeWindow;
  const bridge = { selectFile };
  bridgeWindow.__cmuxMobileDiff = bridge;
  bridgeWindow.webkit?.messageHandlers?.cmuxMobileDiff?.postMessage({
    type: "files",
    files: mobileDiffFiles(source),
    selectedItemId,
  });
  return () => {
    if (bridgeWindow.__cmuxMobileDiff === bridge) {
      delete bridgeWindow.__cmuxMobileDiff;
    }
  };
}

export function useMobileDiffBridge(
  source: FileTreeSource | null,
  selectedItemId: string,
  selectFile: (itemId: string) => void,
): void {
  useEffect(
    () => installMobileDiffBridge(source, selectedItemId, selectFile),
    [source, selectedItemId, selectFile],
  );
}
