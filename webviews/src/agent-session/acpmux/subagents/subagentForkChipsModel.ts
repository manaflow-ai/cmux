import { modelIdName } from "../defaultChoice";
import { harnessFamilyMenu, harnessModeName, shownModes } from "../harnessModes";
import type { Translate } from "../i18n";
import { isHarness } from "./subagentMessage";

/// What a subagent's composer says it runs on (SubagentForkChips.tsx), and what it can be forked
/// onto. Only the truth: a running subagent's model is fixed when it starts (Claude's Agent `model`,
/// its definition's or the chat's; Codex copies the chat's model at its spawn), a Claude subagent's
/// permissions follow its chat's live mode (they `bubble`), and a Codex subagent's mode was copied
/// at its spawn. Nothing here changes the chat's model or mode: a pick forks the subagent.
export type SubagentChipFacts = {
  /// The model's name, as the chip shows it.
  model: string;
  /// The chip's hover: why the model is fixed.
  modelTip: string;
  /// The mode the subagent runs in, by the chat's mode id; none when the chat reports no mode.
  mode?: { id: string; name: string };
  /// The mode chip's hover: whether it follows the chat or was set at the start.
  modeTip: string;
  /// The mode follows the chat's live mode (a Claude subagent's permissions bubble).
  follows: boolean;
  /// Models and modes a fork can start on; empty when the daemon cannot fork a subagent.
  forkModels: { id: string; name: string }[];
  forkModes: { id: string; name: string }[];
};

export type SubagentChipInput = {
  /// The chat's family (`claude`, `codex`) and harness id.
  family?: string;
  harness?: string;
  /// The chat's name, as its tab shows it.
  chat: string;
  /// The chat's model id and its shown name (the model chip's), which a subagent that asked for no
  /// model of its own inherited.
  chatModel?: string;
  chatModelName?: string;
  /// The chat's mode now and the modes it reports.
  modeId?: string;
  modes: readonly { id: string; name: string; description?: string }[];
  /// The models the chat's harness lists (modelCatalog.ts `sessionModels`).
  models: readonly { id: string; name: string }[];
  /// The model the subagent's spawn asked for (Subagent `spawnModel`, an acpmux child's `model`).
  subagentModel?: string;
  /// The daemon forks a subagent (`acp.session.fork.subagent.v1`).
  canFork: boolean;
};

/// A Claude alias (`sonnet`) as its family's name ("Sonnet"); a release by its catalog name, else
/// read off its id.
function modelName(id: string, models: SubagentChipInput["models"], t: Translate): string {
  const listed = models.find((model) => model.id === id);
  if (listed) return listed.name;
  if (/^[a-z]+$/.test(id)) return `${id[0]!.toUpperCase()}${id.slice(1)}`;
  return modelIdName(id, t);
}

export function subagentChipFacts(input: SubagentChipInput, t: Translate): SubagentChipFacts {
  const claude = isHarness(input.family ?? input.harness, "claude");
  const own = input.subagentModel;
  const model = own
    ? modelName(own, input.models, t)
    : (input.chatModelName ?? (input.chatModel ? modelName(input.chatModel, input.models, t) : t("picker.model")));
  const menu = harnessFamilyMenu(input.family, input.harness);
  const modes = shownModes(menu, input.modes, input.modeId).filter((mode) => mode.id !== "plan");
  const current = input.modeId
    ? {
        id: input.modeId,
        name:
          modes.find((mode) => mode.id === input.modeId)?.name ??
          (menu ? harnessModeName(input.family, input.harness, input.modeId) : input.modeId),
      }
    : undefined;
  return {
    model,
    modelTip: own ? t("subagents.fork.modelTipOwn") : t("subagents.fork.modelTip", { chat: input.chat }),
    ...(current ? { mode: current } : {}),
    modeTip: claude
      ? t("subagents.fork.modeFollowsTip", { chat: input.chat })
      : t("subagents.fork.modeFixedTip", { chat: input.chat }),
    follows: claude,
    forkModels: input.canFork ? input.models.map(({ id, name }) => ({ id, name })) : [],
    forkModes: input.canFork ? modes.map(({ id, name }) => ({ id, name })) : [],
  };
}
