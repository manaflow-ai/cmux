

/// Test probes: how many times the group built its step list and each step drew. Unset in the app.
export const stepProbe: { build?: () => void; render?: (key: string) => void } = {};
