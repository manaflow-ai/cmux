// One entry's isolation in the shell: its own error boundary and its own Suspense. The entry's load
// (entryStore.ts) is read with `use`, so a failed import (a syntax or type-strip error, a throw, a
// missing export) and a throw while its sidebar row or header renders both land in this boundary
// and show this entry's error card; the rest of the shell keeps working. The caller keys the
// boundary by the load's version, so a reload after a fix renders afresh.
import { Component, Suspense, use, useSyncExternalStore, type ReactNode } from "react";
import { errorText, type EntryState } from "../entryStore";
import type { GalleryEntry } from "../format";
import { entryError, liveStatus } from "../liveStatus";

type BoundaryProps = { fallback: (error: unknown) => ReactNode; children: ReactNode };

class EntryErrorBoundary extends Component<BoundaryProps, { error: unknown; failed: boolean }> {
  override state = { error: undefined as unknown, failed: false };
  static getDerivedStateFromError(error: unknown) {
    return { error, failed: true };
  }
  override render(): ReactNode {
    return this.state.failed ? this.props.fallback(this.state.error) : this.props.children;
  }
}

function Loaded({ state, render }: { state: EntryState; render: (entry: GalleryEntry) => ReactNode }) {
  return render(use(state.promise));
}

/** Renders `render(entry)` once the entry has loaded, else `loading`, else its error card. */
export function EntryBoundary({
  state,
  render,
  loading,
  compact = false,
}: {
  state: EntryState;
  render: (entry: GalleryEntry) => ReactNode;
  loading: ReactNode;
  compact?: boolean;
}) {
  return (
    <EntryErrorBoundary
      key={`${state.path}:${state.version}`}
      fallback={(error) => <EntryErrorCard path={state.path} error={error} compact={compact} />}
    >
      <Suspense fallback={loading}>
        <Loaded state={state} render={render} />
      </Suspense>
    </EntryErrorBoundary>
  );
}

/** One entry's failure: its file, the dev server's compile error when there is one, else the error. */
export function EntryErrorCard({ path, error, compact }: { path: string; error: unknown; compact?: boolean }) {
  const status = useSyncExternalStore(liveStatus.subscribe, liveStatus.get);
  const compile = entryError(status, path);
  const text = compile
    ? [compile.message, compile.frame, compile.file !== path ? `in ${compile.file}` : ""].filter(Boolean).join("\n\n")
    : errorText(error);
  return (
    <div
      className={`gallery-entry-error${compact ? " gallery-entry-error--compact" : ""}`}
      role="alert"
      data-gallery-entry-error={path}
    >
      <div className="gallery-entry-error-title">
        {compile ? "Compile error" : "Failed to load"} <code>{path}</code>
      </div>
      {compact ? (
        <div className="gallery-entry-error-line">{text.split("\n")[0]}</div>
      ) : (
        <>
          <pre>{text}</pre>
          <p className="gallery-note">
            Only this entry is affected. Fix the file and save: the entry reloads by itself, with no page reload.
          </p>
        </>
      )}
    </div>
  );
}
