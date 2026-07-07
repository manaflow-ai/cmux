package com.manaflow.cmux.mux;

import java.util.Map;

public record UnknownEvent(String event, Map<String, Object> raw) implements MuxEvent {}
