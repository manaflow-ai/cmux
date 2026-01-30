export interface OnHiddenCallback {
    ({ timeStamp, isUnloading }: {
        timeStamp: number;
        isUnloading: boolean;
    }): void;
}
export declare const onHidden: (cb: OnHiddenCallback, once?: boolean) => void;
