export function Callout({
  type = "info",
  children,
}: {
  type?: "info" | "warn";
  children: React.ReactNode;
}) {
  const styles =
    type === "warn"
      ? "border-s-amber-500 bg-amber-500/5"
      : "border-s-blue-500 bg-blue-500/5";

  return (
    <div
      role="note"
      className={`${styles} border-s-2 px-4 py-3 mb-4 rounded-e-lg text-[14px] text-muted leading-relaxed`}
    >
      {children}
    </div>
  );
}
