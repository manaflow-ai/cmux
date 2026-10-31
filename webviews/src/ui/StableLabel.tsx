import "./StableLabel.css";

/** Reserve the widest translated state label without measuring or changing the accessible name. */
export function StableLabel({ label, alternatives }: { label: string; alternatives: readonly string[] }) {
  return (
    <span className="ui-stable-label">
      {[...new Set(alternatives)].map((alternative) => (
        <span key={alternative} className="ui-stable-label__size" aria-hidden="true" data-label={alternative} />
      ))}
      <span>{label}</span>
    </span>
  );
}
