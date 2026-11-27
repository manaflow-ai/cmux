// A detailed workspace row's age (#16688): how long ago the lead session changed, at the row's right edge.
export function RowAge({ age }: { age: string }) {
  return <span className="proto-row-age">{age}</span>;
}
