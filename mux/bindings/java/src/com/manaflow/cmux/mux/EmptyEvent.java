package com.manaflow.cmux.mux;

public record EmptyEvent() implements MuxEvent {
    public String event() {
        return "empty";
    }
}
