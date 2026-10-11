import { trace } from "@opentelemetry/api";
import * as Cause from "effect/Cause";
import * as Exit from "effect/Exit";
import { recordSpanError } from "../telemetry";
import type { Locale } from "../../i18n/routing";
import { isVmWorkflowError } from "./errors";
import { respondVmWorkflowError, type VmWorkflowErrorOverrides } from "./routeHelpers";
import { vmRequestLocale } from "./vmErrorMessages";
import { runVmWorkflowExit, type VmWorkflowProgram } from "./workflows";

/** A route's view of a finished program: the value, or the response that answers its failure. */
export type VmRouteResult<A> =
  | { readonly ok: true; readonly value: A }
  | { readonly ok: false; readonly response: Response };

export type RunVmRouteOptions = {
  /** Source of the response locale; `locale` wins when both are given. */
  readonly request?: Request;
  readonly locale?: Locale;
  /** Route-local responders layered over the shared table in `routeHelpers`. */
  readonly onError?: VmWorkflowErrorOverrides;
};

/**
 * Run a VM control-plane program at the HTTP boundary.
 *
 * A typed failure becomes the response its responder returns; a failure with
 * no responder (shared or route-local) is thrown so `withAuthedVmApiRoute`
 * logs it and answers the generic 500. A defect or interruption is thrown as
 * the squashed cause: those are bugs, not contract errors.
 */
export async function runVmRoute<A>(
  program: VmWorkflowProgram<A>,
  options: RunVmRouteOptions = {},
): Promise<VmRouteResult<A>> {
  const exit = await runVmWorkflowExit(program);
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
  const failure = Cause.failureOption(exit.cause);
  if (failure._tag === "None") throw Cause.squash(exit.cause);
  const error = failure.value;
  if (!isVmWorkflowError(error)) throw error;
  const locale = options.locale ?? (options.request ? vmRequestLocale(options.request) : "en");
  const response = await respondVmWorkflowError(error, { locale }, options.onError);
  if (!response) throw error;
  if (response.status >= 500) {
    // Parity with the thrown path: a server-side failure still marks the
    // request span and leaves a log line, even though it no longer unwinds
    // through the route's catch-all.
    const span = trace.getActiveSpan();
    if (span) recordSpanError(span, error);
    console.error(`[vm-route] ${error._tag} answered ${response.status}`, error);
  }
  return { ok: false, response };
}
