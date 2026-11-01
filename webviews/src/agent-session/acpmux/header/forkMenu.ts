import type { ChatMenuItem } from "./ChatHeaderTools";
import type { Translate } from "../i18n";
import { openForkMenu } from "../conversation/messageMenu";

/** Primary Fork is a leaf action; destination choices never interpose on the ordinary click. */
export function forkMenuRows(
  throughSeq: number,
  fork: () => void,
  t: Translate,
  choose = openForkMenu,
): ChatMenuItem[] {
  return [
    {
      key: "fork",
      label: t("chatMenu.fork"),
      icon: "agent.fork",
      onSelect: (event) => {
        if (event?.altKey && choose(throughSeq, event.currentTarget)) return;
        fork();
      },
    },
    {
      key: "forkTo",
      label: t("chatMenu.forkTo"),
      icon: "agent.fork",
      onSelect: (event) => {
        choose(throughSeq, event?.currentTarget);
      },
    },
  ];
}
