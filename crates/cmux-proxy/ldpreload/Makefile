CC ?= gcc
CFLAGS += -O2 -fPIC -Wall -Wextra -Werror -D_GNU_SOURCE
LDFLAGS += -shared -ldl

TARGET = libworkspace_net.so
SRC = workspace_net.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean

