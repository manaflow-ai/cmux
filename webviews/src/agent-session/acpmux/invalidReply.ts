// A reply from the agent service that this cmux cannot read (a checkpoint, permission or handoff
// answer missing a field or carrying one of the wrong shape). That only happens when the app and
// its agent service are different versions, so the person reads that and its one step, never the
// validator's own words ("Invalid checkpoint attestation.": Leo, 2026-11-05, "it doesn't just work
// if you're displaying bullshit UI"). The field that failed stays on the error as `detail`, for
// the log and a Details disclosure.
import { type StringKey, type StringValues, translate } from "./i18n";

export class InvalidReplyError extends Error {
  /** The validator's reason in its own words (`error.invalid.*`, `error.unsupported.*`). */
  readonly detail: string;
  constructor(reason: StringKey, values?: StringValues) {
    super(translate("error.versionMismatch"));
    this.name = "InvalidReplyError";
    this.detail = translate(reason, values);
  }
}

/** The error a protocol reader throws for a reply it cannot read. */
export function invalidReply(reason: StringKey, values?: StringValues): InvalidReplyError {
  return new InvalidReplyError(reason, values);
}
