import type { ChatMenuItem } from "./chatHeaderToolsModel";
import type { Translate } from "../i18n";
import { openForkMenu } from "../conversation/messageMenu";
import { FORK_ICON } from "../icons/forkIcon";

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
      icon: FORK_ICON,
      onSelect: (event) => {
        if (event?.altKey && choose(throughSeq, event.currentTarget)) return;
        fork();
      },
    },
    {
      key: "forkTo",
      label: t("chatMenu.forkTo"),
      icon: FORK_ICON,
      onSelect: (event) => {
        choose(throughSeq, event?.currentTarget);
      },
    },
  ];
}

/**
 * Another agent's row: where the chat forks onto that agent in place (`forks`, `chat.switchModel`), it
 * says Fork to Agent… with the fork mark and sits beside Fork, so forking to another agent reads as
 * a fork, one row away (Leo: "too many steps here ... more ergonomic, more intuitive"). Where it
 * cannot fork, it stays Hand off to…, the continuation review, in its own group.
 */
export function agentForkRows(
  targets: readonly { id: string; name: string }[],
  state: { forks: boolean; disabled: boolean; handOffLabel: string },
  pick: (harness: string) => void,
  t: Translate,
): { fork: ChatMenuItem[]; handOff: ChatMenuItem[] } {
  if (targets.length === 0) return { fork: [], handOff: [] };
  const row: ChatMenuItem = {
    // One key either way: the palette's Continue In… opens this row's children by it (`expand`).
    key: "continue",
    label: state.forks ? t("chatMenu.forkToAgent") : state.handOffLabel,
    icon: state.forks ? FORK_ICON : "agent.handoff",
    disabled: state.disabled,
    children: targets.map((target) => ({ key: target.id, label: target.name, onSelect: () => pick(target.id) })),
  };
  return state.forks ? { fork: [row], handOff: [] } : { fork: [], handOff: [row] };
}
