export function safeSetPointerCapture(element, pointerId) {
  if (!element?.setPointerCapture || pointerId == null) return false;
  try {
    element.setPointerCapture(pointerId);
    return true;
  } catch {
    return false;
  }
}

export function safeReleasePointerCapture(element, pointerId) {
  if (!element?.releasePointerCapture || pointerId == null) return false;
  try {
    element.releasePointerCapture(pointerId);
    return true;
  } catch {
    return false;
  }
}
