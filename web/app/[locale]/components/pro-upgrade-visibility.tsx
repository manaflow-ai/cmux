"use client";

import {
  isClientConfigFlagEnabled,
  useClientConfigFlag,
} from "../../lib/client-config";
import { FEATURE_FLAGS } from "../../lib/feature-flags";

const FORCE = process.env.NEXT_PUBLIC_CMUX_PRO_UPGRADE_UI_ENABLED;
const FORCED_ON =
  FORCE === "1" ||
  (FORCE === undefined && process.env.NODE_ENV === "development");
const FORCED_OFF = FORCE === "0";

export function ProUpgradeVisibility({
  children,
}: {
  children: React.ReactNode;
}) {
  const flagEnabled = useClientConfigFlag(FEATURE_FLAGS.proUpgradeUI.key);
  const visible =
    !FORCED_OFF &&
    (FORCED_ON ||
      isClientConfigFlagEnabled(
        flagEnabled,
        FEATURE_FLAGS.proUpgradeUI.defaultWhenUnavailable,
      ));

  return visible ? <>{children}</> : null;
}
