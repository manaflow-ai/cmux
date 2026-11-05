export type EngineLaunchFailure = {
  engine: string;
  error: string;
  stage: "launch" | "selection";
};

export type EngineCoverage = {
  expectedEngines: string[];
  measuredEngines: string[];
  expectedCount: number;
  measuredCount: number;
  complete: boolean;
};

export type EngineSelection<T> = {
  launched: Array<{ engine: string; value: T }>;
  failures: EngineLaunchFailure[];
  coverage: EngineCoverage;
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Launch each selected engine independently so one failure cannot erase the other engine's evidence. */
export async function launchSelectedEngines<T>(
  selectedEngines: readonly string[],
  launch: (engine: string) => Promise<T>,
): Promise<EngineSelection<T>> {
  const launched: Array<{ engine: string; value: T }> = [];
  const failures: EngineLaunchFailure[] = [];
  for (const engine of selectedEngines) {
    try {
      launched.push({ engine, value: await launch(engine) });
    } catch (error) {
      failures.push({ engine, error: errorMessage(error), stage: "launch" });
    }
  }
  const expectedEngines = [...selectedEngines];
  const measuredEngines = launched.map(({ engine }) => engine);
  return {
    launched,
    failures,
    coverage: {
      expectedEngines,
      measuredEngines,
      expectedCount: expectedEngines.length,
      measuredCount: measuredEngines.length,
      complete: failures.length === 0 && measuredEngines.length === expectedEngines.length,
    },
  };
}

export function invalidEngineSelection(engine: string, error: string): EngineSelection<never> {
  return {
    launched: [],
    failures: [{ engine, error, stage: "selection" }],
    coverage: {
      expectedEngines: [engine],
      measuredEngines: [],
      expectedCount: 1,
      measuredCount: 0,
      complete: false,
    },
  };
}

export function shouldFailRun(actionFailureCount: number, engineFailureCount: number, noFail: boolean): boolean {
  return !noFail && (actionFailureCount > 0 || engineFailureCount > 0);
}
