/// Whether a key or pointer event waits for the main thread (Chromium's `isInputPending`; false
/// where the browser has none). Work that could wait a frame checks it so input goes first.
export const inputPending = (): boolean => {
  const scheduling = (globalThis.navigator as { scheduling?: { isInputPending?: () => boolean } } | undefined)
    ?.scheduling;
  try {
    return scheduling?.isInputPending?.() === true;
  } catch {
    return false;
  }
};
