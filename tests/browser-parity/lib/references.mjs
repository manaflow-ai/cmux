// Where the reference implementations live on this machine. The parity
// harness names them reference-a and reference-b; the product each name
// stands for, and the paths to set here, are kept outside this repository.
//
//   PARITY_REFERENCE_A_CLI        reference A's CLI (its `repl` subcommand
//                                 runs one program)
//   PARITY_REFERENCE_B_RUNTIME    reference B's runtime directory (its
//                                 bin/node loads diff/reference-b-runner.ts);
//                                 CUA_REFERENCE_RUNTIME is read as well, and
//                                 the reference client's other CUA_REFERENCE_*
//                                 settings pass through unchanged
//   PARITY_PLAYWRIGHT_DIR         a node_modules directory holding playwright
//                                 (lib/dev-driver.mjs), when it is not
//                                 resolvable from here
function required(name, what) {
  const v = process.env[name];
  if (!v) throw new Error(`set ${name} to ${what}`);
  return v;
}

export const referenceACli = () => required("PARITY_REFERENCE_A_CLI", "reference A's CLI");
export const referenceBRuntime = () => process.env.CUA_REFERENCE_RUNTIME || required("PARITY_REFERENCE_B_RUNTIME", "reference B's runtime directory");
