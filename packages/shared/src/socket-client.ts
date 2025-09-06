import type {
  ClientToServerEvents,
  ServerToClientEvents,
  ServerToWorkerEvents,
  WorkerToServerEvents,
} from "./socket-schemas.js";
import { io, type Socket } from "socket.io-client";
export type { Socket } from "socket.io-client";

export interface MainServerClientParams {
  url: string;
  authToken: string;
  teamSlugOrId?: string;
  authJson?: unknown;
  transports?: ("websocket" | "polling")[];
}

export function buildMainClientQuery(params: Omit<MainServerClientParams, "url">): Record<string, string> {
  const query: Record<string, string> = { auth: params.authToken };
  if (params.teamSlugOrId) query.team = params.teamSlugOrId;
  if (params.authJson !== undefined) query.auth_json = JSON.stringify(params.authJson);
  return query;
}

export function connectToMainServer(
  params: MainServerClientParams
): Socket<ServerToClientEvents, ClientToServerEvents> {
  const { url, transports = ["websocket"], ...rest } = params;
  const query = buildMainClientQuery(rest);
  return io(url, { transports, query }) as Socket<ServerToClientEvents, ClientToServerEvents>;
}

export interface WorkerManagementClientParams {
  url: string; // base worker URL, e.g., http://host:39377
  timeoutMs?: number;
  reconnectionAttempts?: number;
  forceNew?: boolean;
}

export function connectToWorkerManagement(
  params: WorkerManagementClientParams
): Socket<WorkerToServerEvents, ServerToWorkerEvents> {
  const {
    url,
    timeoutMs = 30_000,
    reconnectionAttempts = 10,
    forceNew = true,
  } = params;

  return io(`${url}/management`, {
    reconnection: true,
    reconnectionAttempts,
    reconnectionDelay: 2000,
    reconnectionDelayMax: 10_000,
    timeout: timeoutMs,
    transports: ["websocket"],
    upgrade: false,
    forceNew,
  }) as Socket<WorkerToServerEvents, ServerToWorkerEvents>;
}
