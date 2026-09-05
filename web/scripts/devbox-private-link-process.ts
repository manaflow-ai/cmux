import { Effect } from "effect";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";

const attempt = <A>(label: string, run: (signal: AbortSignal) => Promise<A>) =>
  Effect.tryPromise({ try: run, catch: () => new Error(label) });

function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(() => child.kill("SIGKILL"), 2_000);
    child.once("close", () => { clearTimeout(timer); resolve(); });
    child.kill("SIGTERM");
  });
}

function start(client: string, args: string[]) {
  return Effect.acquireRelease(
    attempt("Could not start the verification client", () => new Promise<ChildProcess>((resolve, reject) => {
      const child = spawn(client, args, { stdio: ["ignore", "pipe", "pipe"] });
      // Keep draining headless state events and stderr without logging identity
      // or invitation material. A failed step is named by its caller.
      child.stdout!.resume();
      child.stderr!.resume();
      child.once("error", reject);
      child.once("spawn", () => resolve(child));
    })),
    (child) => Effect.promise(() => stop(child)),
  );
}

function waitForSocket(socket: string, child: ChildProcess) {
  return Effect.gen(function* () {
    while (!existsSync(socket)) {
      if (child.exitCode !== null || child.signalCode !== null) {
        return yield* Effect.fail(new Error("Private connection process exited before becoming ready"));
      }
      yield* Effect.sleep("100 millis");
    }
  }).pipe(Effect.timeoutFail({ duration: "30 seconds", onTimeout: () => new Error("Private connection did not become ready") }));
}


export function startPrivateLinkClient(client: string, args: string[], ready: {
  event: "hub-ready" | "connection-snapshot";
  socket: string;
}) {
  return start(client, args).pipe(Effect.map((child) => ({
    child,
    ready: waitForSocket(ready.socket, child),
  })));
}
