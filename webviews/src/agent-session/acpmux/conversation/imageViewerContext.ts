import { createContext } from "react";

/// Opens the image viewer on an inline image (ImageViewer.tsx); absent where the pane has no viewer.
export const ImageViewerContext = createContext<((src: string, alt: string) => void) | undefined>(undefined);
