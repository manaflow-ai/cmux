export function createCoalescedRefresh(
  operation: () => Promise<void>,
  onError: (error: unknown) => void = () => {},
): () => void {
  let dirty = false;
  let running = false;

  const drain = async () => {
    if (running) return;
    running = true;
    try {
      while (dirty) {
        dirty = false;
        try {
          await operation();
        } catch (error) {
          onError(error);
        }
      }
    } finally {
      running = false;
      if (dirty) void drain();
    }
  };

  return () => {
    dirty = true;
    void drain();
  };
}
