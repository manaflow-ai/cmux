export declare function getOsRelease(): Promise<Record<string, string> | null>;
export declare function parseOsRelease(data: string): Promise<Record<string, string>>;
export declare function getProvidedRuntime(): Promise<"provided.al2023" | "provided.al2">;
