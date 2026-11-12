import { createContext } from "react";
import type { FollowMotionArm } from "./followMotion.experiment";

/// Forces the follow motion's arm (followMotion.experiment.ts) for the transcripts under it, in
/// place of `experimentArm`. Only the gallery's side-by-side preview (followMotionPreview.gallery.tsx)
/// provides it, so several transcripts on one page each run their own arm; with no provider (the
/// app) the arm comes from the experiment as before.
export const FollowArmOverride = createContext<FollowMotionArm | undefined>(undefined);
