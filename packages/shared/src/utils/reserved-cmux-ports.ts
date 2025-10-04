export const RESERVED_CMUX_PORTS = [39376, 39377, 39378, 39379] as const;

export const RESERVED_CMUX_PORT_SET = new Set<number>(RESERVED_CMUX_PORTS);
