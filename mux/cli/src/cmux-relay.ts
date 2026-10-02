// The mux runs in the acpmux daemon, which cmux-next does not admit to its
// control socket (cmuxOnly mode admits only processes the app started). The
// supervisor is started from a cmux terminal, so it is admitted; it relays
// `cmux` commands from the mux over a private Unix socket. Rights end when
// the supervisor stops.

import { chmodSync, rmSync } from "node:fs";

export interface RelayRequest {
  argv: string[];
}

export interface RelayResponse {
  code: number;
  stdout: string;
  stderr: string;
}

const MAX_OUTPUT = 256 * 1024;
const TIMEOUT_MS = 60_000;

/** Serves relay requests on `path` until the process exits. `run` executes one cmux command. */
export function serveRelay(
  path: string,
  run: (argv: string[]) => Promise<RelayResponse> = runCmux,
) {
  rmSync(path, { force: true });
  const server = Bun.listen<{ buffer: string }>({
    unix: path,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
      },
      async data(socket, chunk) {
        socket.data.buffer += new TextDecoder().decode(chunk);
        const newline = socket.data.buffer.indexOf("\n");
        if (newline < 0) return;
        let response: RelayResponse;
        try {
          const request = JSON.parse(socket.data.buffer.slice(0, newline)) as RelayRequest;
          if (!Array.isArray(request.argv) || !request.argv.every((a) => typeof a === "string"))
            throw new Error("bad request");
          response = await run(request.argv);
        } catch (error) {
          response = { code: 2, stdout: "", stderr: String(error) };
        }
        socket.write(`${JSON.stringify(response)}\n`);
        socket.end();
      },
    },
  });
  chmodSync(path, 0o600);
  return server;
}

/** Runs `cmux argv` with this process's environment (the cmux terminal's socket and CLI). */
export async function runCmux(argv: string[]): Promise<RelayResponse> {
  const child = Bun.spawn(["cmux", ...argv], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), TIMEOUT_MS);
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  clearTimeout(timer);
  return { code, stdout: stdout.slice(0, MAX_OUTPUT), stderr: stderr.slice(0, MAX_OUTPUT) };
}

/** Sends one command to the relay and returns its result. */
export async function relay(path: string, argv: string[]): Promise<RelayResponse> {
  return new Promise<RelayResponse>((resolve, reject) => {
    let buffer = "";
    Bun.connect({
      unix: path,
      socket: {
        open(socket) {
          socket.write(`${JSON.stringify({ argv } satisfies RelayRequest)}\n`);
        },
        data(_socket, chunk) {
          buffer += new TextDecoder().decode(chunk);
        },
        close() {
          try {
            resolve(JSON.parse(buffer) as RelayResponse);
          } catch {
            reject(new Error("the mux supervisor closed the cmux relay without answering"));
          }
        },
        error(_socket, error) {
          reject(error);
        },
      },
    }).catch(() =>
      reject(
        new Error(
          "no cmux relay: run `mux up` in a terminal of the cmux app the mux should control",
        ),
      ),
    );
  });
}
