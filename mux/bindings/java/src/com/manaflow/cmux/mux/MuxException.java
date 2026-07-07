package com.manaflow.cmux.mux;

public class MuxException extends Exception {
    public MuxException(String message) {
        super(message);
    }

    public MuxException(String message, Throwable cause) {
        super(message, cause);
    }
}
