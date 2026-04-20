import { Suspense } from "react";
import { StackHandler } from "@stackframe/stack";
import { stackServerApp } from "../../lib/stack";

export default function StackHandlerPage(props: { params: Promise<{ stack: string[] }> }) {
  return (
    <Suspense>
      <StackHandler fullPage app={stackServerApp} params={props.params} />
    </Suspense>
  );
}
