// l10n-allow-file: public-safe gallery fixtures.
import { useState } from "react";
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
import { OnboardingContext } from "./parts";
import { OnboardingStore } from "./store";
import { WalkArmScreen, type WalkArm } from "./walkArms";

export type OnboardingGalleryProps = {
  step?: "agents" | "importData" | "computerUse" | "agentTools" | "makeItYours";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  agentTools?: AgentToolsFixture;
  look?: AgentsLook;
  makeItYours?: MakeItYoursFixture;
  makeLook?: MakeItYoursLook;
  /** An intro-walk arm (walkArms.tsx): a gallery-only screen in the same window, over the Make cmux
   * Yours fixture. Absent: the shipped page. */
  walk?: WalkArm;
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
  walk,
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
    return new OnboardingStore(new MockOnboardingProvider(step), state);
  });
  const [strings] = useState(() => createStrings(table));
  if (walk)
    return (
      <OnboardingContext.Provider value={{ strings, store }}>
        <WalkArmScreen arm={walk} />
      </OnboardingContext.Provider>
    );
  return <OnboardingPage store={store} strings={strings} agentsLook={look} makeItYoursLook={makeLook} />;
}
