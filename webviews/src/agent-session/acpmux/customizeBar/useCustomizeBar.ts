import { useCallback, useEffect, useRef, useState } from "react";
import { pageHostClient } from "../pageHostClient";
import { barState, refusalMessage, type CustomizeBarState, type CustomizeVerb } from "./customizeBarModel";
import type { CustomizeBarOutcome } from "./CustomizeBar";
import type { PageClient } from "../../../pages/shared/pageClient";

const OP = "cmux.customize.run";
const IDLE: CustomizeBarState = { kind: "idle" };

async function runAction(page: PageClient, verb: CustomizeVerb, arg?: string): Promise<CustomizeBarOutcome> {
  try {
    const answer = await page.call<unknown>(OP, arg === undefined ? { verb } : { verb, arg });
    const refused = refusalMessage(answer);
    if (refused !== undefined) return { kind: "failed", message: refused };
    if (verb === "apply") return { kind: "applied" };
    if (verb === "save" && arg) return { kind: "saved", name: arg };
    return { kind: "none" };
  } catch (error) {
    return { kind: "failed", message: error instanceof Error ? error.message : String(error) };
  }
}

/// The bar's status and actions. It reads `cmux customize status` when it mounts, when the chat's
/// turn ends (an agent's `customize_*` calls happen in a turn), and after each of its own actions:
/// no timer. Off (`enabled` false) or with no page host, it never calls.
export function useCustomizeBar(enabled: boolean, working: boolean) {
  const [state, setState] = useState<CustomizeBarState>(IDLE);
  const [outcome, setOutcome] = useState<CustomizeBarOutcome>({ kind: "none" });
  const reads = useRef(0);

  const refresh = useCallback(async () => {
    const page = pageHostClient();
    if (!enabled || !page) return;
    const read = ++reads.current;
    try {
      const answer = await page.call<unknown>(OP, { verb: "status" });
      if (read === reads.current) setState(barState(answer));
    } catch {
      // No CLI or an old host: the bar stays as it was.
    }
  }, [enabled]);

  const wasWorking = useRef(working);
  useEffect(() => {
    const ended = wasWorking.current && !working;
    wasWorking.current = working;
    if (ended) {
      setOutcome({ kind: "none" });
      void refresh();
    }
  }, [working, refresh]);
  useEffect(() => {
    void refresh();
  }, [refresh]);

  const run = useCallback(
    async (verb: CustomizeVerb, arg?: string) => {
      const page = pageHostClient();
      if (!page) return;
      setOutcome({ kind: "busy", verb });
      setOutcome(await runAction(page, verb, arg));
      await refresh();
    },
    [refresh],
  );

  return { state, outcome, run };
}
