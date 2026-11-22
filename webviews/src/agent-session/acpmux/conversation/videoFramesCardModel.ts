import { createContext } from "react";

export type VideoFramesLayout = "strip" | "grid" | "poster";

/// The layout the transcript's cards take: `strip`, but for the gallery's comparison.
export const VideoFramesLayoutContext = createContext<VideoFramesLayout>("strip");
