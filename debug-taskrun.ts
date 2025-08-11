import { ConvexHttpClient } from "convex/browser";
import { api } from "./packages/convex-local/convex/_generated/api.js";

async function debugTaskRun() {
  const client = new ConvexHttpClient(process.env.NEXT_PUBLIC_CONVEX_URL || "https://feeble-chipmunk-966.convex.cloud");
  
  // Get the latest tasks
  const tasks = await client.query(api.tasks.list, {});
  
  if (tasks.length === 0) {
    console.log("No tasks found");
    return;
  }
  
  // Get the most recent task that has runs
  for (const task of tasks.slice(0, 5)) {
    console.log(`\n\n====== TASK: ${task.text} (${task._id}) ======`);
    
    // Get task runs for this task
    const taskRuns = await client.query(api.taskRuns.getByTask, { taskId: task._id });
    console.log(`Found ${taskRuns.length} task runs`);
    
    if (taskRuns.length === 0) continue;
    
    // Check each run's log
    for (const run of taskRuns) {
      console.log(`\n=== Run ${run._id} (${run.status}) ===`);
      const agentMatch = run.prompt.match(/\(([^)]+)\)$/);
      const agentName = agentMatch ? agentMatch[1] : "Unknown";
      console.log(`Agent: ${agentName}`);
      console.log(`Log length: ${run.log.length} chars`);
      console.log(`Is crowned: ${run.isCrowned}`);
      
      // Look for git diff patterns
      const patterns = [
        "diff --git",
        "new file mode", 
        "create mode",
        "insertions(+)",
        "file changed",
        "=== GIT DIFF ===",
        "modified:",
        "deleted:",
        "+++ b/",
        "--- a/"
      ];
      
      console.log("\nPattern matches:");
      for (const pattern of patterns) {
        if (run.log.includes(pattern)) {
          const index = run.log.lastIndexOf(pattern);
          console.log(`✓ Contains '${pattern}' at position ${index}`);
        }
      }
      
      // Show last 1000 chars of log
      console.log("\nLast 1000 chars of log:");
      console.log("---START---");
      console.log(run.log.slice(-1000));
      console.log("---END---");
    }
  }
}

debugTaskRun().catch(console.error);