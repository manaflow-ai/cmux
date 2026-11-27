/**
 * Terminals: interactive shells on a VM over WebSocket. A terminal session
 * outlives its connection: closing the socket only detaches, and the session
 * can be listed, reattached or closed later.
 *
 * Frame protocol on the socket, both directions:
 * - binary frames are raw terminal bytes (output from the VM, input to it);
 * - text frames from the server are JSON: `{"type":"sessionInfo","sessionId":N,"name":"...","created":true}`
 *   first, then `{"type":"exited","exitCode":N}` or `{"type":"error","message":"..."}`;
 * - text frames from the client are JSON: `{"type":"resize","cols":N,"rows":N}` or
 *   `{"type":"signal","signal":"sigint"|"sigkill"}`. Anything else is dropped.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { Conflict, NotFound, QuotaExceeded } from "../errors.ts";
import { describe, GroupTeamHeaders, UpgradeRequired } from "./common.ts";

/** A guest Linux user name. */
export const LinuxUser = Schema.String.pipe(Schema.pattern(/^[a-z_][a-z0-9_-]{0,31}$/));

/** A session name: lowercase letters, digits and hyphens, not all digits (ids are bare integers). */
export const TerminalName = Schema.String.pipe(
  Schema.pattern(/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/),
  Schema.filter((value) => !/^[0-9]+$/.test(value), { message: () => "a terminal name must not be all digits" }),
);

const Dimension = Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 1000));

export const OpenTerminalParams = Schema.Struct({
  /** Command to run; omit for a login shell. */
  command: Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(8192))),
  cols: Schema.optional(Dimension),
  rows: Schema.optional(Dimension),
  /** Guest Linux user to run as; omit for the guest's default user. */
  user: Schema.optional(LinuxUser),
  /**
   * Name the session to reattach to it later. If a session already has this
   * name, that session is returned and `command` is not run; the first
   * `sessionInfo` frame's `created` says which happened.
   */
  name: Schema.optional(TerminalName),
  /** Respawn the shell in place when it exits, keeping the session's id, name and scrollback. */
  restartOnExit: Schema.optional(Schema.BooleanFromString),
});

export const TerminalUserParams = Schema.Struct({
  /** Only sessions owned by this guest Linux user. */
  user: Schema.optional(LinuxUser),
});

export class TerminalSession extends Schema.Class<TerminalSession>("TerminalSession")({
  /** Per-VM session id, for attaching or closing this session. */
  sessionId: Schema.Int,
  name: Schema.NullOr(Schema.String),
  state: Schema.Literal("running", "exited", "unknown"),
  user: Schema.NullOr(Schema.String),
  cols: Schema.Int,
  rows: Schema.Int,
  exitCode: Schema.NullOr(Schema.Int),
  createdAt: Schema.String,
}) {}

export class TerminalSessionList extends Schema.Class<TerminalSessionList>("TerminalSessionList")({
  items: Schema.Array(TerminalSession),
}) {}

export class ClosedTerminal extends Schema.Class<ClosedTerminal>("ClosedTerminal")({
  sessionId: Schema.Int,
  /** Exit code if the session had already exited; null when it was still running and was hung up. */
  exitCode: Schema.NullOr(Schema.Int),
}) {}

const VmPath = Schema.Struct({ vmId: Schema.String });
/** `terminal` is a session id or the name the session was opened with. */
const TerminalPath = Schema.Struct({ vmId: Schema.String, terminal: Schema.String });

const SwitchingProtocols = HttpApiSchema.Empty(101);

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class TerminalsGroupDefinition extends HttpApiGroup.make("terminals")
  .add(
    HttpApiEndpoint.get("openTerminal", "/v1/vms/:vmId/terminal")
      .setPath(VmPath)
      .setUrlParams(OpenTerminalParams)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(SwitchingProtocols)
      .addError(NotFound)
      .addError(Conflict)
      .addError(UpgradeRequired)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Open a terminal on the VM over a WebSocket",
          "vm:terminal",
          "Send `Upgrade: websocket`. Frames pass through unbuffered; see the TerminalSession schema for the session fields.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listTerminals", "/v1/vms/:vmId/terminals")
      .setPath(VmPath)
      .setUrlParams(TerminalUserParams)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(TerminalSessionList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("List the VM's terminal sessions, running and recently exited", "vm:terminal")),
  )
  .add(
    HttpApiEndpoint.get("attachTerminal", "/v1/vms/:vmId/terminals/:terminal")
      .setPath(TerminalPath)
      .setUrlParams(TerminalUserParams)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(SwitchingProtocols)
      .addError(NotFound)
      .addError(Conflict)
      .addError(UpgradeRequired)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Reattach to a terminal session over a WebSocket",
          "vm:terminal",
          "Send `Upgrade: websocket`. Retained scrollback replays first, then live output follows.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.del("closeTerminal", "/v1/vms/:vmId/terminals/:terminal")
      .setPath(TerminalPath)
      .setUrlParams(TerminalUserParams)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClosedTerminal)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(describe("Kill a terminal session and remove it", "vm:terminal")),
  ) {}
