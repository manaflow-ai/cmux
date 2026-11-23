// l10n-allow-file: public-safe gallery fixtures.
import { useState } from "react";
import { createStrings } from "../shared/i18n";
import type { AgentsLook } from "./AgentsStep";
import {
  agentsState,
  computerUseState,
  importState,
  makeItYoursState,
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
  step?: "agents" | "importData" | "computerUse" | "makeItYours";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  look?: AgentsLook;
  makeItYours?: MakeItYoursFixture;
  makeLook?: MakeItYoursLook;
};

export function OnboardingGallery({
  step = "agents",
  agents,
  importer,
  computerUse,
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
          : step === "makeItYours"
            ? makeItYoursState(makeItYours)
            : agentsState(agents);
    return new OnboardingStore(new MockOnboardingProvider(step), state);
  });
  const [strings] = useState(() => createStrings(table));
  return <OnboardingPage store={store} strings={strings} agentsLook={look} makeItYoursLook={makeLook} />;
}
