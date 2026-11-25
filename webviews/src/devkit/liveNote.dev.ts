// The dev server's second script on every page it serves (dev-server/plugins.ts liveRecoveryDevEntry):
// tells the inline cmux Live guard (dev-server/liveRecovery.ts) whether the Vite client holds the
// server, and shows its note while it does not. The Vite client reloads the page when the server is
// back. Production bundles never include this file.
type LiveWindow = Window & { __cmuxLiveNote?: (text: string | null) => void; __cmuxLiveConnected?: boolean };

if (import.meta.hot) {
  const win = window as LiveWindow;
  import.meta.hot.on("vite:ws:connect", () => {
    win.__cmuxLiveConnected = true;
    win.__cmuxLiveNote?.(null);
  });
  import.meta.hot.on("vite:ws:disconnect", () => {
    win.__cmuxLiveConnected = false;
    win.__cmuxLiveNote?.("cmux Live: the dev server stopped. This page reloads when it is back.");
  });
}
