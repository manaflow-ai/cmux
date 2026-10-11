import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { CheckpointClient, type CheckpointClientOptions, type Request } from "./client";
import type { CheckpointTarget } from "./protocol";
import { CheckpointReview } from "./Review";
import type { CheckpointStrings } from "./strings";

/** One intent path for the palette, pane header and Changes toolbar. No snapshot work runs in the page. */
export function useCheckpoints({
  request,
  target,
  online,
  strings,
  options,
  variant = "compact",
}: {
  request: Request;
  target?: CheckpointTarget;
  online: boolean;
  strings: CheckpointStrings;
  options?: CheckpointClientOptions;
  variant?: "compact" | "expanded";
}) {
  const [client] = useState(
    () =>
      new CheckpointClient(request, {
        ...options,
        capabilities:
          options?.capabilities ?? (() => request("git.capabilities", {}) as Promise<{ checkpoints: boolean }>),
      }),
  );
  const subscribe = useCallback((listener: () => void) => client.subscribe(listener), [client]);
  const read = useCallback(() => client.getSnapshot(), [client]);
  const state = useSyncExternalStore(subscribe, read);
  const [open, setOpen] = useState(false);
  const [copyError, setCopyError] = useState(false);
  const cwd = target?.cwd;
  const sessionId = target?.sessionId;
  const hostKind = target?.hostKind;
  const currentTarget = useMemo(() => (cwd ? { cwd, sessionId, hostKind } : undefined), [cwd, sessionId, hostKind]);
  useEffect(() => {
    client.select(currentTarget);
    setOpen(false);
    setCopyError(false);
  }, [client, currentTarget]);
  // Mount and reconnect are the only capability reads. There is no catalog fetch or polling.
  useEffect(() => {
    client.setOnline(online);
    if (online) void client.refreshCapabilities();
  }, [client, online]);
  const supported = state.supported && online && !!currentTarget?.cwd && currentTarget.hostKind !== "cloud";
  const valid = useRef(supported);
  valid.current = supported;
  const ignore = (promise: Promise<unknown>) => void promise.catch(() => undefined);
  const show = useCallback(() => {
    if (!valid.current || !client.beginReview()) return;
    setOpen(true);
    setCopyError(false);
    ignore(
      (async () => {
        await client.recoverPending();
        if (!client.getSnapshot().pending && !client.getSnapshot().record)
          await client.list({ include_candidates: true });
      })(),
    );
  }, [client]);
  const error = state.error;
  const message = copyError
    ? strings.failed
    : !online
      ? strings.offline
      : error?.reason === "repository_changed"
        ? strings.changed
        : error?.code === "operation.unsupported"
          ? strings.unsupported
          : error
            ? (error.origin === "session_host" || error.origin === "native") && error.message !== error.code
              ? error.message
              : strings.failed
            : undefined;
  const review =
    open && (supported || !online) ? (
      <CheckpointReview
        key={`${currentTarget?.sessionId ?? ""}:${currentTarget?.cwd ?? ""}:${state.record?.checkpoint_id ?? "draft"}`}
        list={state.list}
        record={state.record}
        busy={!online ? "offline" : state.busy}
        pending={!!state.pending}
        error={message}
        strings={strings}
        variant={variant}
        onCancel={() => setOpen(false)}
        onRefresh={() => ignore(client.list({ include_candidates: true }))}
        onRetry={() => ignore(client.retry())}
        onCreate={(paths) => {
          if (!state.list) return;
          ignore(
            client.create({
              include_untracked: paths,
              expected_repository_id: state.list.repository_id,
              expected_worktree_id: state.list.worktree_id,
              reason: "manual",
            }),
          );
        }}
        onKeep={(record) =>
          ignore(
            client.pin({
              checkpoint_id: record.checkpoint_id,
              pin_id: `user:${crypto.randomUUID()}`,
              reason: "manual",
            }),
          )
        }
        onRelease={(record, pinId) => ignore(client.unpin({ checkpoint_id: record.checkpoint_id, pin_id: pinId }))}
        onCopy={async (record) => {
          setCopyError(false);
          try {
            await navigator.clipboard.writeText(record.ref);
          } catch (error) {
            setCopyError(true);
            throw error;
          }
        }}
      />
    ) : null;
  return { supported, show, review, open: !!review };
}
