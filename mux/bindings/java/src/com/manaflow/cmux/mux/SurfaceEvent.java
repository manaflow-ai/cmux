package com.manaflow.cmux.mux;

public record SurfaceEvent(String event, long surface) implements MuxEvent {}
