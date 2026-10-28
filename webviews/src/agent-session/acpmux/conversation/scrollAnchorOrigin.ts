/**
 * The browser's scrollTop is quantized while row geometry may move by fractional CSS pixels.
 * Keep that residual in the existing thread placement origin instead of adding another scroll write.
 * The caller resets the origin when navigation, clamping or a session change owns the pass.
 */
export type FractionalAnchorCorrection = {
  desiredLogicalTop: number;
  origin: number;
};

export function fractionalAnchorCorrection({
  previousPhysicalTop,
  previousOrigin,
  layoutDelta,
  actualPhysicalTop,
  maxResidual = 1,
}: {
  previousPhysicalTop: number;
  previousOrigin: number;
  layoutDelta: number;
  actualPhysicalTop: number;
  maxResidual?: number;
}): FractionalAnchorCorrection {
  const desiredLogicalTop = previousPhysicalTop - previousOrigin + layoutDelta;
  const residual = actualPhysicalTop - desiredLogicalTop;
  // A large difference is a clamp/navigation or a stale write, not CSS quantization. Fail closed
  // by rebasing at the actual browser position rather than carrying a bad origin into later rows.
  if (!Number.isFinite(residual) || Math.abs(residual) > maxResidual)
    return { desiredLogicalTop: actualPhysicalTop, origin: 0 };
  return { desiredLogicalTop, origin: residual };
}
