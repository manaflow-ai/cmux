export default function StackHandlerLoading() {
  return (
    <main
      aria-busy="true"
      className="flex min-h-screen items-center justify-center"
    >
      <div
        aria-hidden="true"
        className="h-5 w-5 animate-spin rounded-full border-2 border-current border-t-transparent"
      />
    </main>
  );
}
