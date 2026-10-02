// The composer of the reference (home.png, overview.png): an optional context bar (project,
// host, branch), the Milkdown input ("Do anything"), and a bar with +, the permission chip,
// the model chip and the round send button (a stop square while a turn runs). Picks go to
// acpmux (chat.mode, chat.model, chat.effort); the draft is view state until sent.
import { useRef, useState } from "react";
import { MilkdownInput, type MilkdownInputHandle } from "../markdown-editor/MilkdownInput";
import { anchorProps, COMPOSER_ANCHORS } from "../shell/anchors";
import {
  IconArrowUp,
  IconBranch,
  IconChevronDown,
  IconFolder,
  IconLaptop,
  IconPlus,
  IconShieldAlert,
} from "../shell/icons";
import { StopSquare } from "../conversation/icons";
import type { AcpmuxSnapshot } from "../data/acpmux";
import { PermissionMenu, isUnrestricted, type ModeChoice } from "./PermissionMenu";
import { ModelMenu, type Choice } from "./ModelMenu";
import { act } from "./useAcpmuxPane";

export type PromptComposerProps = {
  snapshot: AcpmuxSnapshot;
  /** Context chips above the input (the new chat hero shows them). */
  context?: { project?: string; host?: string; branch?: string };
  draft?: string;
  onSend: (markdown: string) => void;
  onStop: () => void;
};

type Menu = "permission" | "model" | undefined;

export function PromptComposer({ snapshot, context, draft, onSend, onStop }: PromptComposerProps) {
  const [menu, setMenu] = useState<Menu>();
  const [hasText, setHasText] = useState(Boolean(draft?.trim()));
  const input = useRef<MilkdownInputHandle>(undefined);
  const summary = snapshot.summary;
  const modes: ModeChoice[] = (summary?.modes?.availableModes ?? []).map((mode) => ({
    id: mode.id,
    name: mode.name || mode.id,
    description: mode.description,
  }));
  const mode = modes.find((choice) => choice.id === summary?.modes?.currentModeId);
  const models: Choice[] = (snapshot.catalog.find((harness) => harness.id === summary?.harness)?.models ?? []).map(
    (model) => ({
      id: model.id,
      name: model.name || model.id,
    }),
  );
  const effortOption = summary?.configOptions?.find(
    (option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort",
  );
  const efforts: Choice[] = (effortOption?.options ?? []).map((option) => ({
    id: option.value,
    name: option.name || option.value,
  }));
  const modelName = models.find((choice) => choice.id === summary?.model)?.name ?? summary?.model;
  const effortName = efforts.find((choice) => choice.id === effortOption?.currentValue)?.name;
  const send = (markdown: string) => {
    if (!markdown.trim()) return;
    onSend(markdown);
    input.current?.set("");
    setHasText(false);
  };
  const toggle = (next: Menu) => setMenu((current) => (current === next ? undefined : next));
  return (
    <div className="cx-composer-wrap pt-composer">
      {context && (
        <div className="cx-context">
          {context.project && (
            <span className="cx-chip">
              <IconFolder size={16} />
              <span>{context.project}</span>
            </span>
          )}
          {context.host && (
            <span className="cx-chip">
              <IconLaptop size={16} />
              <span>{context.host}</span>
            </span>
          )}
          {context.branch && (
            <span className="cx-chip">
              <IconBranch size={16} />
              <span>{context.branch}</span>
            </span>
          )}
        </div>
      )}
      <div className="cx-composer" {...anchorProps(COMPOSER_ANCHORS.box)}>
        <div className="cx-composer__input">
          <MilkdownInput
            initial={draft}
            placeholder="Do anything"
            onSubmit={send}
            onChange={(markdown) => setHasText(markdown.trim() !== "")}
            onReady={(handle) => (input.current = handle)}
          />
        </div>
        <div className="cx-composer__bar">
          <button type="button" className="cx-composer__plus pt-bare" aria-label="Add files">
            <IconPlus size={16} strokeWidth={1.5} />
          </button>
          {modes.length > 0 && (
            <button
              type="button"
              className={`cx-permission pt-bare${menu === "permission" ? " is-active" : ""}${mode && !isUnrestricted(mode.id) ? " is-safe" : ""}`}
              onClick={() => toggle("permission")}
              {...anchorProps(COMPOSER_ANCHORS.permission)}
            >
              <IconShieldAlert size={16} strokeWidth={1.25} />
              <span>{mode?.name ?? "Permissions"}</span>
            </button>
          )}
          <span className="cx-composer__spacer" />
          {(modelName || effortName) && (
            <button
              type="button"
              className="cx-model pt-bare"
              onClick={() => toggle("model")}
              {...anchorProps(COMPOSER_ANCHORS.model)}
            >
              {modelName && <span className="cx-model__name">{modelName}</span>}
              {effortName && <span className="cx-model__effort">{effortName}</span>}
              <IconChevronDown className="cx-model__chevron" size={14} strokeWidth={1.1} />
            </button>
          )}
          {snapshot.isWorking && !hasText ? (
            <button type="button" className="cx-send cx-send--ready pt-bare" aria-label="Stop" onClick={onStop}>
              <StopSquare size={16} />
            </button>
          ) : (
            <button
              type="button"
              className={`cx-send cx-send--${hasText ? "ready" : "idle"} pt-bare`}
              aria-label="Send"
              disabled={!hasText}
              onClick={() => send(input.current?.markdown() ?? "")}
            >
              <IconArrowUp size={16} strokeWidth={1.4} />
            </button>
          )}
        </div>
        {menu === "permission" && (
          <PermissionMenu
            modes={modes}
            current={mode?.id}
            onDismiss={() => setMenu(undefined)}
            onPick={(id) => {
              setMenu(undefined);
              act("chat.mode", { modeId: id });
            }}
          />
        )}
        {menu === "model" && (
          <ModelMenu
            models={models}
            model={summary?.model}
            efforts={efforts}
            effort={effortOption?.currentValue}
            onDismiss={() => setMenu(undefined)}
            onModel={(id) => act("chat.model", { modelId: id })}
            onEffort={(value) => effortOption && act("chat.effort", { configId: effortOption.id, value })}
          />
        )}
      </div>
    </div>
  );
}
