// l10n-allow-file: public-safe gallery fixtures.
import { useState, useEffect, useRef } from "react";
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
  withReadiness,
} from "./fixtures";
import type { MakeItYoursLook } from "./MakeItYoursStep";
import table from "./generated/strings.json";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingContext } from "./parts";
import { OnboardingStore } from "./store";
import type { MakeItYoursScreen } from "./walk";
import { WalkArmScreen, type WalkArm } from "./walkArms";
import {
  READINESS,
  type ReadinessFixture,
  type ReadinessFixtureCase,
} from "../shared/signIn/galleryFixtures";

export type OnboardingGalleryProps = {
  step?: "agents" | "importData" | "computerUse" | "makeItYours";
  agents?: AgentsFixture;
  importer?: ImportFixture;
  computerUse?: ComputerUseFixture;
  look?: AgentsLook;
  makeItYours?: MakeItYoursFixture;
  makeLook?: MakeItYoursLook;
  /** An intro-walk arm (walkArms.tsx): a gallery-only screen in the same window, over the Make cmux
   * Yours fixture. Absent: the shipped page. */
  walk?: WalkArm;
  /** experiments.introWalk on: Make cmux Yours as the walk's four screens, opened on `makeScreen`. */
  introWalk?: boolean;
  makeScreen?: MakeItYoursScreen;
  /** The host's sign-in state on the agents step (shared/signIn/galleryFixtures.ts READINESS): sent
   * as `signInReadiness` and `signInAccounts`, its sign-in started through the mock's op. */
  readiness?: ReadinessFixture;
};

export function OnboardingGallery({
  step = "agents",
  agents,
  importer,
  computerUse,
  look,
  makeItYours,
  makeLook,
  walk,
  introWalk,
  makeScreen,
  readiness,
}: OnboardingGalleryProps) {
  const [mock] = useState(() => {
    const base =
      step === "importData"
        ? importState(importer)
        : step === "computerUse"
          ? computerUseState(computerUse)
          : step === "makeItYours"
            ? makeItYoursState(makeItYours, { introWalk })
            : agentsState(agents);
    const state = readiness ? withReadiness(base, READINESS[readiness]) : base;
    return { provider: new MockOnboardingProvider(step, state), state };
  });
  const [store] = useState(
    () => new OnboardingStore(mock.provider, mock.state),
  );
  const [strings] = useState(() => createStrings(table));
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!readiness) return;
    // The page follows the mock host's changes (a finished sign-in turns the row ready).
    void store.start();
    // The sign-in the case shows, started the way a click starts it: held on its code, or refused.
    const fixture: ReadinessFixtureCase = READINESS[readiness];
    const signIn = fixture.signIn;
    if (signIn) {
      if (signIn.refusal) mock.provider.signIn.refusal = signIn.refusal;
      else mock.provider.signIn.hold = new Promise<void>(() => {});
      root.current
        ?.querySelector<HTMLButtonElement>(
          `[data-ready-family="${signIn.family}"] [data-ready-action="signIn"]`,
        )
        ?.click();
    }
    return () => store.stop();
  }, [readiness, store, mock]);
  if (walk)
    return (
      <OnboardingContext.Provider value={{ strings, store }}>
        <WalkArmScreen arm={walk} />
      </OnboardingContext.Provider>
    );
  return (
    <div ref={root} style={{ display: "contents" }}>
      <OnboardingPage
        store={store}
        strings={strings}
        agentsLook={look}
        makeItYoursLook={makeLook}
        makeItYoursScreen={makeScreen}
      />
    </div>
  );
}
