/// A load deadline, then one outstanding challenge at a time. Only its answer renews the deadline.
export function renderWatchdog(stop: (reason: "load" | "hang") => void) {
  let timer: ReturnType<typeof setTimeout>;
  let target: Window | undefined;
  let id: string | undefined;
  let started = false;
  let answered = false;
  let disposed = false;
  const expire = () => {
    disposed = true;
    stop(answered ? "hang" : "load");
  };
  const ping = () => {
    if (disposed) return;
    id = crypto.randomUUID();
    target?.postMessage({ type: "cmux-render-ping", id }, "*");
    // A document rewrite can erase the listener after the page has already answered.
    timer = setTimeout(expire, answered ? 30000 : 5000);
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
      answered = true;
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

export function renderHeartbeatPage(html: string): string {
  const leading = /^(\s*(?:<!--[\s\S]*?-->\s*)*<!doctype\b[^>]*>)/i.exec(html)?.[0] ?? "";
  return leading + renderHeartbeatScript() + html.slice(leading.length);
}
