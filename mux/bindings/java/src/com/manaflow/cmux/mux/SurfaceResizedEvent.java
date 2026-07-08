package com.manaflow.cmux.mux;

public record SurfaceResizedEvent(long surface, int cols, int rows) implements MuxEvent {
    public String event() {
        return "surface-resized";
    }
}
