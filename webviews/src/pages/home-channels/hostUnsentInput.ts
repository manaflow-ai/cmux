// `cmux.host.home.input.unsent {unsent}`: the page tells its app host whether any composer holds
// text or files not sent yet, each time that changes (HomeChannelsInput.swift). While it does, the
// host keeps the page when its tab hides for long: a page made again would lose that input. This
// is Chrome's model, where the renderer reports a page's form interaction to the browser and the
// discard policy reads it (discard_eligibility_policy.cc, kFormInteractions). Absent in a browser
// or the gallery: there is no host to tell.
import { createContext, useContext, useEffect, useRef } from "react";
import type { PageClient } from "../shared/pageClient";

export const UNSENT_INPUT_OP = "cmux.host.home.input.unsent";

/** The composers holding unsent input; the host hears each time the page goes between none and some. */
export class UnsentInputReport {
  private readonly holding = new Set<object>();
  /** What the host last heard; it starts at none, and undefined after a report that failed. */
  private reported: boolean | undefined = false;

  constructor(private readonly host: Pick<PageClient, "call">) {}

  /** Whether any composer holds unsent input. */
  get unsent(): boolean {
    return this.holding.size > 0;
  }

  /** `owner` (one composer) holds unsent input or not; the host hears only a change of the whole. */
  set(owner: object, unsent: boolean): void {
    if (unsent) this.holding.add(owner);
    else this.holding.delete(owner);
    const now = this.unsent;
    if (now === this.reported) return;
    this.reported = now;
    // A refused or lost report is sent again with the next change.
    this.host.call(UNSENT_INPUT_OP, { unsent: now }).catch(() => {
      if (this.reported === now) this.reported = undefined;
    });
  }
}

export const UnsentInput = createContext<UnsentInputReport | undefined>(undefined);

/** Reports this composer's unsent input while it is mounted (none once it unmounts). */
export function useUnsentInput(unsent: boolean): void {
  const report = useContext(UnsentInput);
  const owner = useRef({});
  useEffect(() => {
    report?.set(owner.current, unsent);
  }, [report, unsent]);
  useEffect(() => {
    const self = owner.current;
    return () => report?.set(self, false);
  }, [report]);
}
