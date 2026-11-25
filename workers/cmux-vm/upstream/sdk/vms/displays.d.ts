import type { FreestyleClient } from "../client.js";
/** @internal Experimental Personal-plan VMs only; not part of the published API contract. */
export interface DisplaySize {
    width: number;
    height: number;
}
/** @internal */
export interface DisplayStatus {
    id: string;
    /** Mode offered to the guest; adoption is asynchronous. */
    requested: DisplaySize;
    /** Actual guest scanout. Zero dimensions mean there is no image yet. */
    scanout: DisplaySize;
    generation: number;
}
/** @internal */
export interface DisplayFrame {
    /** Pass back as `after` to wait for the next change. */
    generation: number;
    width: number;
    height: number;
    cursor?: {
        x: number;
        y: number;
    };
    /** PNG bytes; absent while the guest shows no image. */
    png?: Uint8Array;
}
/** @internal */
export type DisplayKeyboardEvent = {
    type: "press" | "release";
    key: number;
};
/** @internal */
export type DisplayPointerEvent = {
    type: "move_absolute";
    x: number;
    y: number;
} | {
    type: "press" | "release";
    button: "left" | "right" | "middle" | "side" | "extra";
} | {
    type: "scroll";
    horizontal: number;
    vertical: number;
};
/**
 * @internal Experimental. Each display is an independent guest output with
 * its own frames, so one app window per display streams independently.
 */
export declare class VmDisplays {
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, basePath: string);
    list(): Promise<{
        generation: number;
        displays: DisplayStatus[];
    }>;
    create(options: DisplaySize & {
        id: string;
        accelerated?: boolean;
    }): Promise<DisplayStatus>;
    delete(id: string): Promise<{
        displays: DisplayStatus[];
    }>;
    /** Request widths in multiples of 8; the guest rounds others down. */
    resize(id: string, size: DisplaySize): Promise<DisplayStatus>;
    /** With `after`, waits (up to about 20 s) for that display to change. */
    frame(id: string, options?: {
        after?: number;
        signal?: AbortSignal;
    }): Promise<DisplayFrame>;
    /**
     * Each inner array is one input report. Pointer coordinates are 0..32767
     * across `display` when given (offset onto the guest desktop by the
     * manager), otherwise across the whole desktop.
     */
    input(reports: {
        display?: string;
        keyboard?: DisplayKeyboardEvent[][];
        pointer?: DisplayPointerEvent[][];
    }): Promise<unknown>;
}
//# sourceMappingURL=displays.d.ts.map