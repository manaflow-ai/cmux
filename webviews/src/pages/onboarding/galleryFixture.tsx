// l10n-allow-file: public-safe gallery fixtures.
import { useState } from "react";
import { createStrings } from "../shared/i18n";
import type { AgentsLook } from "./AgentsStep";
import {
  agentToolsState,
  agentsState,
  computerUseState,
  importState,
  type AgentToolsFixture,
  type AgentsFixture,
  type ComputerUseFixture,
  type ImportFixture,
} from "./fixtures";
import table from "./generated/strings.json";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

export type OnboardingGalleryProps = {
  step?: "agents" | "importData" | "computerUse" | "agentTools";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  agentTools?: AgentToolsFixture;
  look?: AgentsLook;
};

export function OnboardingGallery({
  step = "agents",
  agents,
  importer,
  computerUse,
  agentTools,
  look,
}: OnboardingGalleryProps) {
  const [store] = useState(() => {
    const state =
      step === "importData"
        ? importState(importer)
        : step === "computerUse"
          ? computerUseState(computerUse)
          : step === "agentTools"
            ? agentToolsState(agentTools)
            : agentsState(agents);
    return new OnboardingStore(new MockOnboardingProvider(step), state);
  });
  const [strings] = useState(() => createStrings(table));
  return <OnboardingPage store={store} strings={strings} agentsLook={look} />;
}
