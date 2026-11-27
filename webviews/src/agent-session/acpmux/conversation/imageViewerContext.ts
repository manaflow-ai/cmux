import { createContext } from "react";

/// Opens the image viewer on an inline image (ImageViewer.tsx), with the file it was read from when
/// a reply named one (Show in Finder selects that file); absent where the pane has no viewer.
export const ImageViewerContext = createContext<((src: string, alt: string, path?: string) => void) | undefined>(
  undefined,
);
