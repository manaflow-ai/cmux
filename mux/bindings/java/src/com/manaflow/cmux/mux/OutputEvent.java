package com.manaflow.cmux.mux;

public record OutputEvent(long surface, String data) implements MuxEvent {
    public String event() {
        return "output";
    }
}
