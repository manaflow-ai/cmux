import { useEffect, useRef } from "react";
import { holdWebSwap } from "./webSwap";

/** WEB-SWAP: holds a web update's reload while `reason` is set (pages/shared/webSwap.ts). */
export function useWebSwapHold(reason: string | null | undefined | false): void {
  const current = useRef(reason);
  current.current = reason;
  useEffect(() => holdWebSwap(() => current.current || null), []);
}
