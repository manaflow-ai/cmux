package com.cmux;

import java.util.Map;

public record UnknownEvent(String event, Map<String, Object> raw) implements CmuxEvent {}
