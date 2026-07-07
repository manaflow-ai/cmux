package com.manaflow.cmux.mux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Pane(long id, String name, int activeTab, List<Tab> tabs, boolean dead) {
    @SuppressWarnings("unchecked")
    static Pane from(Map<String, Object> data) {
        List<Tab> tabs = new ArrayList<>();
        Object raw = data.get("tabs");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                tabs.add(Tab.from((Map<String, Object>) item));
            }
        }
        return new Pane(
            MuxClient.asLong(data.get("id")),
            data.get("name") == null ? null : MuxClient.asString(data.get("name")),
            (int) MuxClient.asLong(data.getOrDefault("active_tab", 0)),
            tabs,
            Boolean.TRUE.equals(data.get("dead"))
        );
    }
}
