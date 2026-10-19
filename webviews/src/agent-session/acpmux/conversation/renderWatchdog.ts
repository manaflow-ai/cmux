/// A load deadline, then one outstanding challenge at a time. Only its answer renews the deadline.
export function renderWatchdog(stop: () => void) {
  let timer: ReturnType<typeof setTimeout>;
  let target: Window | undefined;
  let id: string | undefined;
  let started = false;
  let disposed = false;
  const expire = () => {
    disposed = true;
    stop();
  };
  const ping = () => {
    if (disposed) return;
    id = crypto.randomUUID();
    target?.postMessage({ type: "cmux-render-ping", id }, "*");
    timer = setTimeout(expire, 5000);
  };
  timer = setTimeout(expire, 5000);
  return {
    start(frame: Window) {
      if (started || disposed) return;
      started = true;
      target = frame;
      clearTimeout(timer);
      ping();
    },
    pong(value: unknown) {
      if (!started || disposed || id === undefined || value !== id) return;
      clearTimeout(timer);
      // Consume the answer so duplicates cannot keep a hung page alive.
      id = undefined;
      timer = setTimeout(ping, 2000);
    },
    dispose() {
      disposed = true;
      clearTimeout(timer);
    },
  };
}

export function renderHeartbeatSource(): string {
  // l10n-allow: executable frame health protocol
  return `addEventListener('message', function (event) {
    if (event.source === parent && event.data && event.data.type === 'cmux-render-ping')
      parent.postMessage({ type: 'cmux-render-pong', id: event.data.id }, '*');
  });`;
}

export const renderHeartbeatScript = () => `<script>${renderHeartbeatSource()}</script>`;
