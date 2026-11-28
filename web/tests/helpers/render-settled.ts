import type { ReactNode } from "react";
import { prerender } from "react-dom/static";

/** Render async server components and propagate errors that Suspense would defer to hydration. */
export async function renderSettled(element: ReactNode): Promise<string> {
  const errors: unknown[] = [];
  const { prelude } = await prerender(element, {
    onError: (error) => {
      errors.push(error);
    },
  });
  if (errors.length) throw errors[0];
  return new Response(prelude).text();
}
