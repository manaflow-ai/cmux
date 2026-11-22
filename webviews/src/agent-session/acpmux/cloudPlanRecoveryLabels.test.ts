import { expect, test } from "bun:test";
import { cloudPlanRecoveryLabels } from "./cloudPlanRecoveryLabels";

test("Cloud first-send recovery uses the native cap card's localized titles", () => {
  expect(cloudPlanRecoveryLabels("en")).toEqual({ upgrade: "Upgrade", runHere: "Run on This Mac" });
  expect(cloudPlanRecoveryLabels("fr")).toEqual({ upgrade: "Mettre à niveau", runHere: "Exécuter sur ce Mac" });
  expect(cloudPlanRecoveryLabels("ja").runHere).toBe("この Mac で実行");
  expect(cloudPlanRecoveryLabels("pt-BR").upgrade).toBe("Fazer upgrade");
  expect(cloudPlanRecoveryLabels("en-US")).toEqual(cloudPlanRecoveryLabels("en"));
  expect(cloudPlanRecoveryLabels("unknown")).toEqual(cloudPlanRecoveryLabels("en"));
});
