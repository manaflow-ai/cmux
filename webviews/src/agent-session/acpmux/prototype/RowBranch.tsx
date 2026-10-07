// A detailed workspace row's branch (#16688).
import { BranchIcon } from "./icons";

export function RowBranch({ branch }: { branch: string }) {
  return (
    <span className="proto-row-branch" title={branch}>
      <BranchIcon />
      <span>{branch}</span>
    </span>
  );
}
