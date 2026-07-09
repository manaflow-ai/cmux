package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Tree(List<Workspace> workspaces) {
    @SuppressWarnings("unchecked")
    static Tree from(Map<String, Object> data) {
        List<Workspace> workspaces = new ArrayList<>();
        Object raw = data.get("workspaces");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                workspaces.add(Workspace.from((Map<String, Object>) item));
            }
        }
        return new Tree(workspaces);
    }
}
