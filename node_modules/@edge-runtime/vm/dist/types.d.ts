export interface DispatchFetch {
    (input: string, init?: RequestInit): Promise<Response & {
        waitUntil: () => Promise<any>;
    }>;
}
export interface RejectionHandler {
    (reason?: {} | null, promise?: Promise<any>): void;
}
export interface ErrorHandler {
    (error?: {} | null): void;
}
