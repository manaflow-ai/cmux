export type WorkerRenderOptionsPool<Options> = {
  setRenderOptions(options: Options): Promise<void>;
};

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
