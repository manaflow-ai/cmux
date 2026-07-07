package com.manaflow.cmux.mux;

public record TreeChangedEvent() implements MuxEvent {
    public String event() {
        return "tree-changed";
    }
}
