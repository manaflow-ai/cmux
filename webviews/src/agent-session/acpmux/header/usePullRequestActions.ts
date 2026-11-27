import { useEffect, useEffectEvent, useState, useSyncExternalStore } from "react";
import { useT } from "../i18n";
import type { HeaderPullRequest } from "./headerState";
import { PullRequestActionView, type PullRequestAction, type PullRequestActionName } from "./pullRequestActionView";
export type { PullRequestAction, PullRequestActionName } from "./pullRequestActionView";

/// DOM and native menus share one view and one bounded read per target. Effects never arm a watch.
export function usePullRequestActions(pr: HeaderPullRequest | undefined, run?: PullRequestAction, scope?: string) {
  const t = useT();
  const identity = JSON.stringify([scope, pr?.url, pr?.number, pr?.headSha]);
  const [owned, setOwned] = useState(() => ({ identity, controller: new PullRequestActionView(pr, identity) }));
  let controller = owned.controller;
  if (owned.identity !== identity) {
    controller = new PullRequestActionView(pr, identity);
    setOwned({ identity, controller });
  }
  const view = useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot);
  const displayed = view.head ?? pr;
  const fallback = t("header.prActionFailed");
  const read = useEffectEvent(() => {
    if (run) void controller.invoke("state", run, fallback);
  });
  const available = !!run;
  useEffect(() => {
    controller.activate();
    read();
    return () => controller.dispose();
  }, [controller, available]);
  const action = (kind: PullRequestActionName, label: string) => ({
    id: `${controller.generation}:${kind}`,
    label,
    enabled: !view.busy && (kind === "state" || !!view.head?.headSha),
    run: () => {
      if (run) void controller.invoke(kind, run, fallback);
    },
  });
  const actions: ReturnType<typeof action>[] = [];
  if (displayed && run) {
    actions.push(action("state", t("git.refresh")));
    if (displayed.checks.state === "failing" || displayed.checkList.some((c) => c.state === "failed"))
      actions.push(action("fixChecks", t(view.busy === "fixChecks" ? "header.prFixingChecks" : "header.prFixChecks")));
    actions.push(
      action(
        "addressComments",
        t(view.busy === "addressComments" ? "header.prAddressingComments" : "header.prAddressComments"),
      ),
    );
    if (displayed.state === "open") actions.push(action("arm", t("header.prMergeWhenReady")));
  }
  return {
    actions,
    displayed,
    headSha: view.head?.headSha,
    actionMessages: view.message ? [view.message] : [],
  };
}
