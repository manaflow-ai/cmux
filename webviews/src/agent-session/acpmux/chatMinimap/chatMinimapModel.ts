import { experimentArm } from "../../../experiments/experiment";
import { chatMinimapPlaceholder } from "./placeholder.experiment";

/// While the rows keep changing, the picture follows at most this often.
export const REDRAW_MS = 250;
/// The placeholder's look: the shimmer, except in the gallery, which compares the others. Only the
/// gallery sets an arm in globalThis.cmuxExperiments; a stored cmux.experiments override is ignored.
export const placeholderLook = () => experimentArm(chatMinimapPlaceholder, { stored: {} });
