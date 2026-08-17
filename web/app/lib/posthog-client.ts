"use client";

import posthog from "posthog-js";

if (typeof window !== "undefined") {
  posthog.init("phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP", {
    api_host: "https://r.cmux.com",
    ui_host: "https://us.posthog.com",
    person_profiles: "identified_only",
    capture_pageview: false,
    capture_pageleave: true,
    advanced_disable_feature_flags: true,
    // The route tracker opens this gate only after resolving the current
    // server-authenticated identity.
    before_send: () => null,
  });
}

export { posthog };
