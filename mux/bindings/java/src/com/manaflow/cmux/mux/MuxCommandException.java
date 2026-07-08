package com.manaflow.cmux.mux;

public final class MuxCommandException extends MuxException {
    private final String serverMessage;
    private final Object commandId;

    public MuxCommandException(String serverMessage, Object commandId) {
        super(serverMessage);
        this.serverMessage = serverMessage;
        this.commandId = commandId;
    }

    public String serverMessage() {
        return serverMessage;
    }

    public Object commandId() {
        return commandId;
    }
}
