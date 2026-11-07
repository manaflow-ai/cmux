// Retired operator probe for classic Cloud. Do not provision classic VMs here.
console.error(
  "The classic VM-scope probe is retired. NEXT Cloud model-plane checks belong in cmux-platform. " +
  "On feat-cmux-next, run web/scripts/cmux-vm-image/dev-e2e.ts from the repository root for a NEXT machine/link smoke. " +
  "No credentials were read and no machine was created.",
);
process.exitCode = 1;
