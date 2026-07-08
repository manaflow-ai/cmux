package com.cmux;

import java.util.Map;

public sealed interface CmuxEvent permits TreeChangedEvent, EmptyEvent, SurfaceEvent, SurfaceResizedEvent, VtStateEvent, OutputEvent, ResizedEvent, UnknownEvent {
    String event();

    static CmuxEvent from(Map<String, Object> raw) {
        String event = CmuxClient.asString(raw.get("event"));
        return switch (event) {
            case "tree-changed" -> new TreeChangedEvent();
            case "empty" -> new EmptyEvent();
            case "surface-output", "surface-exited", "title-changed", "bell", "detached" ->
                new SurfaceEvent(event, CmuxClient.asLong(raw.get("surface")));
            case "surface-resized" -> new SurfaceResizedEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows"))
            );
            case "vt-state" -> new VtStateEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows")),
                CmuxClient.asString(raw.get("data"))
            );
            case "output" -> new OutputEvent(CmuxClient.asLong(raw.get("surface")), CmuxClient.asString(raw.get("data")));
            case "resized" -> new ResizedEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows")),
                CmuxClient.asString(raw.get("replay"))
            );
            default -> new UnknownEvent(event, raw);
        };
    }
}
