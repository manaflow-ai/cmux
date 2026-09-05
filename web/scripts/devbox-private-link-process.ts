// Maintainer-only verification subprocesses; these diagnostics are not product CLI copy.
import { Effect } from "effect";
import { spawn, type ChildProcess } from "node:child_process";
import { StringDecoder } from "node:string_decoder";

type ReadyEvent = {
  event: "hub-ready" | "connection-snapshot";
  socket: string;
};

/** Wait for the child owner's close event after sending a termination signal. */
function terminate(child: ChildProcess, signal: NodeJS.Signals) {
  return Effect.async<void>((resume) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resume(Effect.void);
      return;
    }
    const closed = () => resume(Effect.void);
    child.once("close", closed);
    child.kill(signal);
    return Effect.sync(() => child.off("close", closed));
  });
}

/** Close owns completion; the deadline only escalates an unresponsive child. */
function stop(child: ChildProcess) {
  return terminate(child, "SIGTERM").pipe(
    Effect.interruptible,
    Effect.timeoutOption("2 seconds"),
    Effect.flatMap((completed) => completed._tag === "Some" ? Effect.void : terminate(child, "SIGKILL")),
  );
}

/** Match only the expected owner's readiness event and the exact requested socket. */
function isReady(line: string, expected: ReadyEvent): boolean {
  try {
    const event = JSON.parse(line) as Record<string, unknown>;
    const key = expected.event === "hub-ready" ? "socket" : "local_socket";
    return event?.event === expected.event && event[key] === expected.socket;
  } catch {
    return false;
  }
}

/**
 * Observe stdout from spawn onward, retaining an early ready event until awaited.
 * The readiness promise never rejects unobserved while enrollment is approved.
 * Exit/error before readiness fails immediately; socket file existence is irrelevant.
 */
function launch(client: string, args: string[], expected: ReadyEvent) {
  return Effect.async<{ child: ChildProcess; ready: Effect.Effect<void, Error> }, Error>((resume) => {
    const child = spawn(client, args, { stdio: ["ignore", "pipe", "pipe"] });
    let complete!: (ready: boolean) => void;
    const result = new Promise<boolean>((resolve) => { complete = resolve; });
    const decoder = new StringDecoder("utf8");
    let buffered = "";
    let settled = false;
    const finish = (ready: boolean) => {
      if (settled) return;
      settled = true;
      buffered = "";
      complete(ready);
    };
    child.stdout!.on("data", (chunk: Buffer) => {
      if (settled) return; // still drain subsequent connection events
      buffered += decoder.write(chunk);
      if (buffered.length > 1_048_576) { finish(false); return; }
      let boundary: number;
      while (!settled && (boundary = buffered.indexOf("\n")) !== -1) {
        const line = buffered.slice(0, boundary);
        buffered = buffered.slice(boundary + 1);
        if (isReady(line, expected)) finish(true);
      }
    });
    // Diagnostics can carry invitation material; never echo raw child output.
    child.stderr!.resume();
    child.once("close", () => finish(false));
    child.once("error", () => {
      finish(false);
      resume(Effect.fail(new Error("Could not start the verification client")));
    });
    child.once("spawn", () => resume(Effect.succeed({
      child,
      ready: Effect.promise(() => result).pipe(
        Effect.flatMap((ready) => ready ? Effect.void : Effect.fail(new Error("Private connection process exited or returned invalid readiness output"))),
        Effect.timeoutFail({ duration: "30 seconds", onTimeout: () => new Error("Private connection did not announce readiness") }),
      ),
    })));
  });
}

/**
 * Own a headless verifier process until scope exit, including failed startup.
 * acquireRelease masks interruption through acquisition and finalizer registration:
 * cancellation between spawn() and its spawn event still acquires, then stops, the child.
 */
export function startPrivateLinkClient(client: string, args: string[], ready: ReadyEvent) {
  return Effect.acquireRelease(launch(client, args, ready), ({ child }) => stop(child));
}
