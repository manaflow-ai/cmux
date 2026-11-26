// An acpmux permission request as the approval card's permission: its scope, command, diffs and plan.
// Its bodies live in direct/permissions.ts, so the row adapter reads it without the connection client.
export { permissionFromMessage, permissionDiffs, permissionPlan } from "./direct/permissions";
