package com.manaflow.cmux.mux;

public final class MuxTransportException extends MuxException {
    public MuxTransportException(String message, Throwable cause) {
        super(message, cause);
    }

    public MuxTransportException(String message) {
        super(message);
    }
}
