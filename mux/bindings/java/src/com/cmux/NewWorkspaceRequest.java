package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public final class NewWorkspaceRequest {
    private final String name;
    private final Integer cols;
    private final Integer rows;

    private NewWorkspaceRequest(Builder builder) {
        this.name = builder.name;
        this.cols = builder.cols;
        this.rows = builder.rows;
    }

    public static Builder builder() {
        return new Builder();
    }

    Map<String, Object> toMap() {
        Map<String, Object> map = new LinkedHashMap<>();
        if (name != null) {
            map.put("name", name);
        }
        if (cols != null) {
            map.put("cols", cols);
        }
        if (rows != null) {
            map.put("rows", rows);
        }
        return map;
    }

    public static final class Builder {
        private String name;
        private Integer cols;
        private Integer rows;

        public Builder name(String name) {
            this.name = name;
            return this;
        }

        public Builder cols(int cols) {
            this.cols = cols;
            return this;
        }

        public Builder rows(int rows) {
            this.rows = rows;
            return this;
        }

        public NewWorkspaceRequest build() {
            return new NewWorkspaceRequest(this);
        }
    }
}
