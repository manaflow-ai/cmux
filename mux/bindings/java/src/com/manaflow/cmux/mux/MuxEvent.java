package com.manaflow.cmux.mux;

import java.util.Map;

public sealed interface MuxEvent permits TreeChangedEvent, EmptyEvent, SurfaceEvent, SurfaceResizedEvent, VtStateEvent, OutputEvent, ResizedEvent, UnknownEvent {
    String event();

    static MuxEvent from(Map<String, Object> raw) {
        String event = MuxClient.asString(raw.get("event"));
        return switch (event) {
            case "tree-changed" -> new TreeChangedEvent();
            case "empty" -> new EmptyEvent();
            case "surface-output", "surface-exited", "title-changed", "bell", "detached" ->
                new SurfaceEvent(event, MuxClient.asLong(raw.get("surface")));
            case "surface-resized" -> new SurfaceResizedEvent(
                MuxClient.asLong(raw.get("surface")),
                (int) MuxClient.asLong(raw.get("cols")),
                (int) MuxClient.asLong(raw.get("rows"))
            );
            case "vt-state" -> new VtStateEvent(
                MuxClient.asLong(raw.get("surface")),
                (int) MuxClient.asLong(raw.get("cols")),
                (int) MuxClient.asLong(raw.get("rows")),
                MuxClient.asString(raw.get("data"))
            );
            case "output" -> new OutputEvent(MuxClient.asLong(raw.get("surface")), MuxClient.asString(raw.get("data")));
            case "resized" -> new ResizedEvent(
                MuxClient.asLong(raw.get("surface")),
                (int) MuxClient.asLong(raw.get("cols")),
                (int) MuxClient.asLong(raw.get("rows")),
                MuxClient.asString(raw.get("replay"))
            );
            default -> new UnknownEvent(event, raw);
        };
    }
}
