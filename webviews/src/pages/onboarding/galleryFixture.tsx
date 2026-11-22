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
import { OnboardingStore } from "./store";
import { READINESS, type ReadinessFixture } from "../shared/signIn/galleryFixtures";

export type OnboardingGalleryProps = {
  step?: "agents" | "importData" | "computerUse" | "agentTools" | "makeItYours";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  agentTools?: AgentToolsFixture;
  look?: AgentsLook;
  makeItYours?: MakeItYoursFixture;
  makeLook?: MakeItYoursLook;
  /** The providers' readiness rows over the agents step (shared/signIn/galleryFixtures.ts). */
  readiness?: ReadinessFixture;
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
  readiness,
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
  const noop = () => {};
  return (
    <OnboardingPage
      store={store}
      strings={strings}
      agentsLook={look}
      makeItYoursLook={makeLook}
      readiness={
        readiness
          ? {
              rows: READINESS[readiness],
              onAction: noop,
              card: { onCopy: noop, onCancel: noop, onRetry: noop, onDone: noop, onInstall: noop, onSubmitCode: noop },
            }
          : undefined
      }
    />
  );
}
