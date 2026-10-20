// Retained as a fail-closed entry point for stale operator instructions.
console.error("Aurora/RDS IAM migrations are retired. Use bun run cloud-vm:migrate -- <staging|production> for PlanetScale.");
process.exitCode = 1;
