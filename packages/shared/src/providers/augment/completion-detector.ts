export async function startAugmentCompletionDetector(taskRunId: string): Promise<void> {
  const { watch } = await import("node:fs");
  const { access } = await import("node:fs/promises");
  const { constants } = await import("node:fs");
  
  const markerPath = `/root/lifecycle/augment-complete-${taskRunId}`;
  
  return new Promise((resolve) => {
    // First check if the marker already exists
    access(markerPath, constants.F_OK)
      .then(() => {
        console.log(`[Augment Completion] Marker file already exists: ${markerPath}`);
        resolve();
      })
      .catch(() => {
        // File doesn't exist yet, set up watcher
        console.log(`[Augment Completion] Watching for marker file: ${markerPath}`);
        
        const watcher = watch("/root/lifecycle", (_eventType, filename) => {
          if (filename === `augment-complete-${taskRunId}`) {
            console.log(`[Augment Completion] Detected completion marker: ${filename}`);
            watcher.close();
            resolve();
          }
        });
        
        // Also set a timeout to prevent hanging forever
        setTimeout(() => {
          console.log(`[Augment Completion] Timeout waiting for marker file`);
          watcher.close();
          resolve();
        }, 30 * 60 * 1000); // 30 minutes timeout
      });
  });
}