/** Keep account reads inside the route's Suspense boundary. */
export default function PricingLoading() {
  return (
    <main aria-busy="true" className="mx-auto min-h-screen w-full max-w-6xl px-6 py-16 sm:py-20">
      <div className="h-8 w-28 animate-pulse bg-code-bg" />
      <div className="mt-6 grid gap-5 md:grid-cols-3">
        {[0, 1, 2].map((key) => <div key={key} className="h-96 border border-border bg-code-bg" />)}
      </div>
    </main>
  );
}
