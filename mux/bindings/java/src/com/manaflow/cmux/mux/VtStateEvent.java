package com.manaflow.cmux.mux;

public record VtStateEvent(long surface, int cols, int rows, String data) implements MuxEvent {
    public String event() {
        return "vt-state";
    }
}
