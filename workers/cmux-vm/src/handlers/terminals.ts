/**
 * Terminal endpoints. Scope (`vm:terminal`) and VM ownership are proven
 * before anything else, and before the upgrade: a request for another
 * tenant's VM is a plain 404 and never reaches the provider. Only then is the
 * provider socket opened and bridged to the client (src/lib/terminal-bridge.ts).
 */
import { HttpApiBuilder, HttpServerRequest, HttpServerResponse } from "@effect/platform";
import { Effect, Schema } from "effect";
import { CmuxVmApi } from "../api.ts";
import { UpgradeRequired } from "../api/common.ts";
import { ClosedTerminal, TerminalName, TerminalSession, TerminalSessionList } from "../api/terminals.ts";
import { Conflict, NotFound, unavailable, vmNotFound } from "../errors.ts";
import { bridgeTerminal } from "../lib/terminal-bridge.ts";
import type { UpstreamError } from "../upstream/client.ts";
import { UpstreamTerminals, type UpstreamPtySession } from "../upstream/terminals.ts";
import { audited, withOwnedVm } from "./common.ts";

const terminalNotFound = () => new NotFound({ message: "Terminal session not found" });

const isTerminalName = Schema.is(TerminalName);

/** A session id (digits) or a session name; anything else names no session. */
const parseSelector = (raw: string): string | null => (/^[0-9]{1,18}$/.test(raw) || isTerminalName(raw) ? raw : null);

const isWebSocketUpgrade = (request: HttpServerRequest.HttpServerRequest): boolean =>
  (request.headers["upgrade"] ?? "").toLowerCase() === "websocket";

const upgradeRequired = () =>
  new UpgradeRequired({ message: "This endpoint is a WebSocket; send the request with Upgrade: websocket" });

const mapUpstream = (notFound: () => NotFound) => (error: UpstreamError) =>
  error.status === 404
    ? notFound()
    : error.status === 409
      ? new Conflict({ message: "The VM did not respond to the terminal request; try again" })
      : unavailable();

const STATES = ["running", "exited"] as const;

const toSession = (session: UpstreamPtySession): TerminalSession =>
  new TerminalSession({
    sessionId: session.sessionId,
    name: session.slug ?? null,
    state: STATES.find((state) => state === session.state) ?? "unknown",
    user: session.linuxUser ?? null,
    cols: session.cols,
    rows: session.rows,
    exitCode: session.exitCode ?? null,
    createdAt: new Date(session.createdUnix * 1000).toISOString(),
  });

const switchingProtocols = (client: WebSocket) => HttpServerResponse.raw(new Response(null, { status: 101, webSocket: client }));

export const terminalsHandlers = HttpApiBuilder.group(CmuxVmApi, "terminals", (handlers) =>
  handlers
    .handle("openTerminal", ({ path, urlParams }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamTerminals;
        const request = yield* HttpServerRequest.HttpServerRequest;
        return yield* withOwnedVm(path.vmId, "vm:terminal", "exec", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            if (!isWebSocketUpgrade(request)) return yield* Effect.fail(upgradeRequired());
            const socket = yield* audited(
              "terminal.open",
              vm.value,
              upstream
                .openTerminal(vm, proofs, {
                  command: urlParams.command,
                  cols: urlParams.cols,
                  rows: urlParams.rows,
                  user: urlParams.user,
                  name: urlParams.name,
                  restartOnExit: urlParams.restartOnExit,
                })
                .pipe(Effect.mapError(mapUpstream(vmNotFound))),
            );
            return switchingProtocols(bridgeTerminal(socket));
          }),
        );
      }),
    )
    .handle("attachTerminal", ({ path, urlParams }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamTerminals;
        const request = yield* HttpServerRequest.HttpServerRequest;
        return yield* withOwnedVm(path.vmId, "vm:terminal", "exec", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const selector = parseSelector(path.terminal);
            if (selector === null) return yield* Effect.fail(terminalNotFound());
            if (!isWebSocketUpgrade(request)) return yield* Effect.fail(upgradeRequired());
            const socket = yield* audited(
              "terminal.attach",
              vm.value,
              upstream.attachTerminal(vm, proofs, selector, urlParams.user).pipe(Effect.mapError(mapUpstream(terminalNotFound))),
            );
            return switchingProtocols(bridgeTerminal(socket));
          }),
        );
      }),
    )
    .handle("listTerminals", ({ path, urlParams }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamTerminals;
        return yield* withOwnedVm(path.vmId, "vm:terminal", "read", (_caller, vm, proofs) =>
          upstream.listTerminals(vm, proofs, urlParams.user).pipe(
            Effect.map((sessions) => new TerminalSessionList({ items: sessions.map(toSession) })),
            Effect.mapError((error) => (error.status === 404 ? vmNotFound() : unavailable())),
          ),
        );
      }),
    )
    .handle("closeTerminal", ({ path, urlParams }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamTerminals;
        return yield* withOwnedVm(path.vmId, "vm:terminal", "exec", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const selector = parseSelector(path.terminal);
            if (selector === null) return yield* Effect.fail(terminalNotFound());
            const closed = yield* audited(
              "terminal.close",
              vm.value,
              upstream.closeTerminal(vm, proofs, selector, urlParams.user).pipe(Effect.mapError(mapUpstream(terminalNotFound))),
            );
            return new ClosedTerminal({ sessionId: closed.sessionId, exitCode: closed.exitCode ?? null });
          }),
        );
      }),
    ),
);
