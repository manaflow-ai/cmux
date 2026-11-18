// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";

type Props = { line?: string };

export default componentEntry<Props>({
  id: "agent-pane.renderer-restart",
  title: "Restarted after the chat stopped responding",
  area: "Agent pane",
  pane: true,
  height: 100,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/RendererRestartNotice.tsx"],
  load: async () => {
    const { useLayoutEffect } = await import("react");
    const { RendererRestartNotice } = await import("./RendererRestartNotice");
    const store = await import("./rendererRestartStore");
    return function GalleryRendererRestart({ line }: Props) {
      // The app's flag as its new-document script sets it (PageWebView+Liveness.swift).
      useLayoutEffect(() => {
        const globals = globalThis as unknown as Record<string, unknown>;
        // A dismissal holds for the document, and the gallery shows every state in one.
        store.resetRendererRestart();
        if (line) {
          globals[store.RENDERER_RESTART_GLOBAL] = { line };
          store.bootRendererRestart();
        }
        return store.resetRendererRestart;
      }, [line]);
      return (
        <div className="acpmux-shell">
          <RendererRestartNotice />
        </div>
      );
    };
  },
  styles: () => import("./styles.css"),
  variants: {
    restarted: { props: { line: "This chat stopped responding, so cmux restarted it." } },
    cleared: { props: {} },
  },
});
