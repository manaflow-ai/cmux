export type SharePointerBounds = {
  readonly left: number;
  readonly top: number;
  readonly width: number;
  readonly height: number;
};

export type SharePointerCoordinates = {
  readonly x: number;
  readonly y: number;
};

export function sharePointerCoordinates(
  clientX: number,
  clientY: number,
  bounds: SharePointerBounds,
): SharePointerCoordinates | null {
  if (
    !Number.isFinite(clientX) ||
    !Number.isFinite(clientY) ||
    !Number.isFinite(bounds.left) ||
    !Number.isFinite(bounds.top) ||
    !Number.isFinite(bounds.width) ||
    !Number.isFinite(bounds.height) ||
    bounds.width <= 0 ||
    bounds.height <= 0
  ) return null;

  const x = (clientX - bounds.left) / bounds.width;
  const y = (clientY - bounds.top) / bounds.height;
  return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? { x, y } : null;
}
