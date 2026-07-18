export type WorkerRenderOptionsPool<Options> = {
  setRenderOptions(options: Options): Promise<void>;
};

export async function synchronizeWorkerRenderOptions<Options>({
  codeViewReady,
  highlighterOptions,
  render,
  workerPool,
}: {
  codeViewReady: boolean;
  highlighterOptions: Options;
  render: () => void;
  workerPool: WorkerRenderOptionsPool<Options>;
}): Promise<boolean> {
  if (!codeViewReady) {
    return false;
  }
  await workerPool.setRenderOptions(highlighterOptions);
  render();
  return true;
}
