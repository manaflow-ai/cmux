// An extension's part of the New Tab page (`cmux.newtab/1`, picked in `tabs.newTabApp`): a slot
// over cmux's own composer, never in its place (Leo, 2026-11-16, of an extension that replaced the
// page: "it's also unusable, and it also fucks up the app ... the fundamental integration is just so
// stupid"). The composer, its focus and its input-ready report stay cmux's whatever the extension
// does: a refused mount, a render that throws, a host that never answers or a scene that never
// comes only empty this slot, and nothing else on the page or in the pane waits on it.
import {
  Component,
  type ErrorInfo,
  type ReactNode,
  useEffect,
  useEffectEvent,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { AppSceneMount } from "../../../apps/scene/appSceneMount";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import type { PageClient } from "../../../pages/shared/pageClient";
import { pageHostClient } from "../pageHost";
import "./appSlot.css";

/// How long the extension has to draw its first scene before the slot gives up for this visit. The
/// page never waits on it; the deadline only ends the mount, so a host that never answers leaves no
/// work behind.
export const NEW_TAB_APP_DEADLINE_MS = 2000;

type Props = {
  /// The extension the person picked (`tabs.newTabApp`), whose `cmux.newtab/1` draws in the slot.
  app: string;
  /// The folder the new tab starts in: the mount context's `cwd`.
  cwd?: string;
  /// The app is missing, hidden or disabled, failed, threw, went away or did not draw in time: the
  /// slot is empty for the rest of this visit. Called once, with the reason.
  onUnavailable(reason: string): void;
  /// Tests and the gallery inject their host and clock; the page uses the page host's.
  client?: PageClient | null;
  deadlineMs?: number;
};

/** The slot: its room is drawn from the first frame (screen.css `.nt-app-slot`), so the composer
 * under it never moves when the scene arrives or goes. */
export function NewTabAppSlot(props: Props) {
  const [gone, setGone] = useState(false);
  // Exact once: a deadline and a failed status in the same tick both read the last render's `gone`.
  const gaveUp = useRef(false);
  // A plain callback, not an effect event: the boundary and the scene call it from outside this
  // component's effects (SlotScene wraps it in its own effect event).
  const giveUp = (reason: string) => {
    if (gaveUp.current) return;
    gaveUp.current = true;
    setGone(true);
    // The error journal (`cmux errors`) keeps the reason; the page shows none of it.
    console.warn(`New Tab: ${props.app} left its slot empty: ${reason}`);
    props.onUnavailable(reason);
  };
  return (
    <div className="nt-app-slot" data-app={props.app} data-gone={gone || undefined}>
      {!gone && (
        <SlotBoundary onError={(error) => giveUp(`its scene threw: ${String(error)}`)}>
          <SlotScene {...props} onGone={giveUp} />
        </SlotBoundary>
      )}
    </div>
  );
}

function SlotScene({
  app,
  cwd,
  client: injected,
  deadlineMs = NEW_TAB_APP_DEADLINE_MS,
  onGone,
}: Props & { onGone(reason: string): void }) {
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const mount = useMemo(() => new AppSceneMount(client, "newTab", app, cwd ? { cwd } : {}), [client, app, cwd]);
  const status = useSyncExternalStore(mount.store.subscribeStatus, mount.store.getStatus, mount.store.getStatus);
  const gone = useEffectEvent((reason: string) => onGone(reason));
  useEffect(() => {
    if (status.state === "failed" || status.state === "disconnected") gone(status.reason);
  }, [status]);
  useEffect(() => {
    mount.start();
    const stop = () => mount.stop();
    // Native pane retirement can discard the document without unmounting React first.
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      mount.stop();
    };
  }, [mount]);
  const drawn = status.state === "ready";
  useEffect(() => {
    if (drawn) return;
    const timer = setTimeout(() => {
      mount.stop();
      gone(`it did not draw within ${deadlineMs / 1000} s`);
    }, deadlineMs);
    return () => clearTimeout(timer);
  }, [mount, drawn, deadlineMs]);
  return (
    <div className="nt-app-slot-body" data-status={status.state} aria-busy={!drawn}>
      {/* The composer owns focus: a scene that arrives late never takes the rest of a prompt. */}
      <SceneRenderer
        store={mount.store}
        dispatch={mount.dispatch}
        resolveAsset={mount.resolveAsset}
        autofocus={false}
      />
    </div>
  );
}

/** A scene that throws while it draws empties only the slot, never the page around it. */
class SlotBoundary extends Component<{ onError(error: unknown): void; children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    console.error("New Tab: an extension's scene threw", error, info.componentStack);
    this.props.onError(error);
  }

  render() {
    return this.state.failed ? null : this.props.children;
  }
}
