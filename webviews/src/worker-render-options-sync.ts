export type WorkerRenderOptionsPool<Options> = {
  setRenderOptions(options: Options): Promise<void>;
};

export type WorkerRenderOptionsSyncState<Options, Pool> = {
  highlighterOptions: Options;
  workerPool: Pool;
};

export function advanceWorkerRenderOptionsSyncState<Options, Pool>({
  highlighterOptions,
  previous,
  sameOptions,
  workerPool,
}: {
  highlighterOptions: Options;
  previous: WorkerRenderOptionsSyncState<Options, Pool> | null;
  sameOptions: (previous: Options, next: Options) => boolean;
  workerPool: Pool;
}): {
  next: WorkerRenderOptionsSyncState<Options, Pool>;
  shouldSynchronize: boolean;
} {
  const next = { highlighterOptions, workerPool };
  if (previous == null || previous.workerPool !== workerPool) {
    return { next, shouldSynchronize: false };
  }
  return {
    next,
    shouldSynchronize: !sameOptions(previous.highlighterOptions, highlighterOptions),
  };
}

export async function synchronizeWorkerRenderOptions<Options>({
  highlighterOptions,
  render,
  workerPool,
}: {
  highlighterOptions: Options;
  render: () => void;
  workerPool: WorkerRenderOptionsPool<Options>;
}): Promise<boolean> {
  await workerPool.setRenderOptions(highlighterOptions);
  render();
  return true;
}
