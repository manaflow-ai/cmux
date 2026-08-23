import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// The clock's stand-in inside a reactive database: presence is a derived
// claim (lastSeenAt within the lease), but queries re-run on data changes,
// not time. This sweep converts lease expiry into a data transition.
crons.interval("presence lease sweep", { seconds: 30 }, internal.registry.sweep, {});

export default crons;
