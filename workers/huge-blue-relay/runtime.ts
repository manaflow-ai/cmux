/** Small runtime surface, kept explicit because web's typecheck excludes Bun
 * globals. The production process runs on Bun; Node imports never start it. */
export type RelayFrame = string | Uint8Array | ArrayBuffer;
export type RelaySocket<T> = { data: T; send(frame: RelayFrame): number; close(code?: number, reason?: string): void };
export type RelayServer<T> = {
  port: number;
  upgrade(request: Request, options?: { data: T }): boolean;
  stop(force?: boolean): Promise<void>;
};
type Options<T> = {
  hostname: string;
  port: number;
  fetch(request: Request, server: RelayServer<T>): Response | undefined | Promise<Response | undefined>;
  websocket: {
    maxPayloadLength?: number; backpressureLimit?: number; closeOnBackpressureLimit?: boolean;
    open?(peer: RelaySocket<T>): void;
    message(peer: RelaySocket<T>, frame: string | Uint8Array): void;
    close?(peer: RelaySocket<T>): void;
  };
};
export function serve<T = unknown>(options: Options<T>): RelayServer<T> {
  return (globalThis as unknown as { Bun: { serve<T>(options: Options<T>): RelayServer<T> } }).Bun.serve(options);
}
