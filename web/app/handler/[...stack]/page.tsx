import { Suspense } from "react";
import { StackHandler } from "@stackframe/stack";
import { notFound } from "next/navigation";
import { stackHandlerApp } from "../../lib/stack";

export default function StackHandlerPage(props: { params: Promise<{ stack: string[] }> }) {
  if (!stackHandlerApp) notFound();

  return (
    <Suspense>
      <StackHandler fullPage app={stackHandlerApp} params={props.params} />
    </Suspense>
  );
}
