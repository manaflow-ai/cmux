// l10n-allow-file: public-safe gallery fixtures.
import { useEffect, useState } from "react";
import { createStrings } from "../shared/i18n";
import type { AgentsLook } from "./AgentsStep";
import {
  agentToolsState,
  agentsState,
  computerUseState,
  importState,
  makeItYoursState,
  type AgentToolsFixture,
  type AgentsFixture,
  type ComputerUseFixture,
  type ImportFixture,
  type MakeItYoursFixture,
} from "./fixtures";
import type { MakeItYoursLook } from "./MakeItYoursStep";
import table from "./generated/strings.json";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

export type OnboardingGalleryProps = {
  step?: "agents" | "importData" | "computerUse" | "agentTools" | "makeItYours";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  agentTools?: AgentToolsFixture;
  look?: AgentsLook;
  makeItYours?: MakeItYoursFixture;
  makeLook?: MakeItYoursLook;
};

export function OnboardingGallery({
  step = "agents",
  agents,
  importer,
  computerUse,
  agentTools,
  look,
  makeItYours,
  makeLook,
}: OnboardingGalleryProps) {
  const [store] = useState(() => {
    const state =
      step === "importData"
        ? importState(importer)
        : step === "computerUse"
          ? computerUseState(computerUse)
          : step === "agentTools"
            ? agentToolsState(agentTools)
            : step === "makeItYours"
              ? makeItYoursState(makeItYours)
              : agentsState(agents);
    return new OnboardingStore(new MockOnboardingProvider(step, state), state);
  });
  // Started as the app's page is (main.tsx), so a click's change comes back from the mock and the variant answers
  // picks the way the host does (the intro walk probe, scripts/intro-walk.mjs, walks them).
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  const [strings] = useState(() => createStrings(table));
  return <OnboardingPage store={store} strings={strings} agentsLook={look} makeItYoursLook={makeLook} />;
}
