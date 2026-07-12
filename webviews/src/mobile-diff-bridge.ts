import type { FileTreeSource } from "./diff-stream";
import { useEffect } from "react";

export type MobileDiffFile = {
  added: number;
  deleted: number;
  id: string;
  path: string;
};

export type MobileDiffFilesMessage = {
  files: MobileDiffFile[];
  generation: number | null;
  selectedItemId: string;
  type: "files";
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
  selectedItemId: string,
  generation: number | null,
): MobileDiffFilesMessage {
  return {
    type: "files",
    files: mobileDiffFiles(source),
    generation,
    selectedItemId,
  };
}

export function installMobileDiffBridge(
  source: FileTreeSource | null,
  selectedItemId: string,
  generation: number | null,
  selectFile: (itemId: string) => void,
): () => void {
  const bridgeWindow = window as MobileDiffBridgeWindow;
  const bridge = { selectFile };
  bridgeWindow.__cmuxMobileDiff = bridge;
  bridgeWindow.webkit?.messageHandlers?.cmuxMobileDiff?.postMessage(
    mobileDiffMessage(source, selectedItemId, generation),
  );
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
  selectFile: (itemId: string) => void,
): void {
  useEffect(
    () => installMobileDiffBridge(source, selectedItemId, generation, selectFile),
    [source, selectedItemId, generation, selectFile],
  );
}
