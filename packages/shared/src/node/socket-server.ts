import type { ServerOptions } from "socket.io";

export function getMainServerSocketOptions(origin: string = "http://localhost:5173"): Partial<ServerOptions> {
  return {
    cors: {
      origin,
      methods: ["GET", "POST"],
    },
    maxHttpBufferSize: 50 * 1024 * 1024,
    pingTimeout: 120_000,
    pingInterval: 30_000,
    allowEIO3: true,
  } satisfies Partial<ServerOptions>;
}

export function getWorkerServerSocketOptions(): Partial<ServerOptions> {
  return {
    cors: {
      origin: "*",
      methods: ["GET", "POST"],
    },
    maxHttpBufferSize: 50 * 1024 * 1024,
    pingTimeout: 240_000,
    pingInterval: 30_000,
    upgradeTimeout: 30_000,
  } satisfies Partial<ServerOptions>;
}

export function extractQueryParam(value: unknown): string | undefined {
  if (Array.isArray(value)) return typeof value[0] === "string" ? value[0] : undefined;
  return typeof value === "string" ? value : undefined;
}

