package com.manaflow.cmux.mux;

public record ResizedEvent(long surface, int cols, int rows, String replay) implements MuxEvent {
    public String event() {
        return "resized";
    }
}
