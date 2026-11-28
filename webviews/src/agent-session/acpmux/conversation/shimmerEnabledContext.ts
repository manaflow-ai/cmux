import { createContext } from "react";
import { DEFAULT_SHIMMER_CADENCE } from "./shimmerCadence";

export const ShimmerEnabledContext = createContext(true);

/** The sweeps' timing (shimmerCadence.ts). Only the pacing gallery (ShimmerPacing.gallery.tsx) provides
 * another: the app always runs the default. */
export const ShimmerCadenceContext = createContext(DEFAULT_SHIMMER_CADENCE);
