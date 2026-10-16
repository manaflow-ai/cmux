"use client";

import { shellRoute } from "../../routes/root";
import { MobileDevicesPage } from "./mobile-devices-dashboard";

/** The session user is already in the shell context, so nothing loads here. */
export function MobileDevicesScreen() {
  const { session } = shellRoute.useRouteContext();
  return <MobileDevicesPage userId={session.user.id} />;
}
