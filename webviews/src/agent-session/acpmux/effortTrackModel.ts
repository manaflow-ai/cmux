/** The normalized position of a discrete stop, including the track endpoints. */
export function effortStopShare(index: number, stopCount: number): number {
  return stopCount > 1 ? index / (stopCount - 1) : 0;
}

/** The x-coordinate of a thumb or stop center. Both use this endpoint-inclusive geometry. */
export function effortStopCenterX(trackLeft: number, trackWidth: number, index: number, stopCount: number): number {
  return trackLeft + trackWidth * effortStopShare(index, stopCount);
}
