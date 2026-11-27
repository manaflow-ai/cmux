// One frame for all dirty UI subscribers. Sources stay synchronous; only their notifications
// are coalesced, and a subscriber that leaves cannot be called by the pending frame.
const pending = new Set<() => void>();
let frame: number | undefined;

export function frameNotification(notify: () => void) {
  const deliver = () => notify();
  return {
    schedule() {
      pending.add(deliver);
      if (frame !== undefined) return;
      frame = requestAnimationFrame(() => {
        frame = undefined;
        const ready = [...pending];
        for (const callback of ready) {
          if (pending.delete(callback)) callback();
        }
      });
    },
    cancel() {
      pending.delete(deliver);
      if (pending.size === 0 && frame !== undefined) {
        cancelAnimationFrame(frame);
        frame = undefined;
      }
    },
  };
}
