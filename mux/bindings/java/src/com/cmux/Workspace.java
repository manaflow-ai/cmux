package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Workspace(long id, String name, boolean active, List<Screen> screens) {
    @SuppressWarnings("unchecked")
    static Workspace from(Map<String, Object> data) {
        List<Screen> screens = new ArrayList<>();
        Object raw = data.get("screens");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                screens.add(Screen.from((Map<String, Object>) item));
            }
        }
        return new Workspace(
            CmuxClient.asLong(data.get("id")),
            CmuxClient.asString(data.get("name")),
            Boolean.TRUE.equals(data.get("active")),
            screens
        );
    }
}
