// The team board inside the Cloud page (`cmux-page://cmux.cloud/#/board`). The board's ops (types.ts
// `BoardOps`) run on the Cloud page's own bridge, which the app already serves from the Cloud app
// server, so the board needs no host code of its own:
//   snapshot  `cmux.cloud.machine.board`, the platform's board read as it came.
//   stop      `cmux.cloud.machine.pause` with a fresh key. The pause answers the Cloud app's record,
//             so the answer is the machine's board record from a read made after it.
//   open      the Cloud page's confirmed connect (`cmux.app.action.run`, the native sheet); a
//             declined sheet answers `{opened: false}`.
//   changes   the Cloud machine watch: each machine change re-reads the board and sends it as a
//             `snapshot` event, one read at a time with at most one queued behind it.
import type { PageCallOptions, PageClient } from "../shared/pageClient";
import { ACTION_RUN, CloudOps } from "../cloud/ops";
import { BoardOps, type BoardEvent, type BoardSnapshot, type TeamMachine } from "./types";

/** The Cloud page's fragment that shows the board. */
export const CLOUD_BOARD_ROUTE = "#/board";

export function isBoardRoute(hash: string): boolean {
  return hash === CLOUD_BOARD_ROUTE || hash === `${CLOUD_BOARD_ROUTE}/`;
}

/** The board's client over the Cloud page's `cloud` client. `newKey` makes each mutation's key. */
export function cloudBoardClient(cloud: PageClient, newKey: () => string = () => crypto.randomUUID()): PageClient {
  const read = () => cloud.call<BoardSnapshot>(CloudOps.machineBoard, {});
  const machineOf = (params: unknown) => (params as { machine?: unknown } | null)?.machine;
  return {
    handle: (op, handler) => cloud.handle(op, handler),
    async call<R>(op: string, params: unknown, options?: PageCallOptions): Promise<R> {
      switch (op) {
        case BoardOps.snapshot:
          return (await read()) as R;
        case BoardOps.stop: {
          const machine = machineOf(params);
          const paused = await cloud.call<{ machine?: TeamMachine } | null>(CloudOps.machinePause, {
            machine,
            idempotency_key: newKey(),
          });
          const board = await read().catch(() => null);
          const record = board?.machines?.find((row) => row?.id === machine);
          return (record ?? paused?.machine ?? null) as R;
        }
        case BoardOps.open: {
          const answer = await cloud.call<{ confirmed?: boolean } | null>(ACTION_RUN, {
            action: CloudOps.machineConnect,
            args: { machine: machineOf(params), idempotency_key: newKey() },
          });
          return { opened: answer?.confirmed === true } as R;
        }
        default:
          return cloud.call<R>(op, params, options);
      }
    },
    async subscribe<E>(
      stream: string,
      onEvent: (data: E, seq: number) => void,
      filter?: Record<string, unknown>,
    ): Promise<() => void> {
      if (stream !== BoardOps.changes) return cloud.subscribe<E>(stream, onEvent, filter);
      let reading = false;
      let queued = false;
      let closed = false;
      let seq = 0;
      const refresh = async () => {
        if (reading) {
          queued = true;
          return;
        }
        reading = true;
        try {
          do {
            queued = false;
            const snapshot = await read().catch(() => null);
            const event: BoardEvent | null = snapshot ? { kind: "snapshot", snapshot } : null;
            if (event && !closed) onEvent(event as E, ++seq);
          } while (queued && !closed);
        } finally {
          reading = false;
        }
      };
      const stop = await cloud.subscribe(CloudOps.machineWatch, () => void refresh());
      return () => {
        closed = true;
        stop();
      };
    },
  };
}
