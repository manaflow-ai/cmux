export function Callout({
  type = "info",
  children,
}: {
  type?: "info" | "warn";
  children: React.ReactNode;
}) {
  const styles =
    type === "warn"
      ? "border-l-amber-500 bg-amber-500/5"
      : "border-l-blue-500 bg-blue-500/5";

  return (
    <div
      className={`${styles} border-l-2 px-4 py-3 mb-4 rounded-r-lg text-[14px] text-muted leading-relaxed`}
    >
      {children}
    </div>
  );
}
