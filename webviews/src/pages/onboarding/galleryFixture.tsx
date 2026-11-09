// l10n-allow-file: public-safe gallery fixtures.
import { useState } from "react";
import { createStrings } from "../shared/i18n";
import type { AgentsLook } from "./AgentsStep";
import {
  agentsState,
  computerUseState,
  importState,
  type AgentsFixture,
  type ComputerUseFixture,
  type ImportFixture,
} from "./fixtures";
import table from "./generated/strings.json";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

export type OnboardingGalleryProps = {
  step?: "agents" | "importData" | "computerUse";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  look?: AgentsLook;
};

export function OnboardingGallery({ step = "agents", agents, importer, computerUse, look }: OnboardingGalleryProps) {
  const [store] = useState(() => {
    const state =
      step === "importData"
        ? importState(importer)
        : step === "computerUse"
          ? computerUseState(computerUse)
          : agentsState(agents);
    return new OnboardingStore(new MockOnboardingProvider(step), state);
  });
  const [strings] = useState(() => createStrings(table));
  return <OnboardingPage store={store} strings={strings} agentsLook={look} />;
}
