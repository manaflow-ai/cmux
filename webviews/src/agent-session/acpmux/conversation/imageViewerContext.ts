import { createContext } from "react";

/** The opener's viewport rectangle for the optional anchored image handoff. */
export type ImageSourceRect = { left: number; top: number; width: number; height: number };

export type OpenImage = (src: string, alt: string, path?: string, sourceRect?: ImageSourceRect) => void;

/// Opens the image viewer on an inline image (ImageViewer.tsx), with the file it was read from when
/// a reply named one (Show in Finder selects that file); absent where the pane has no viewer.
export const ImageViewerContext = createContext<OpenImage | undefined>(undefined);
