BUILD_DIR ?= $(CURDIR)/build/server
PREFIX ?= /usr/local
SUDO ?= sudo

.PHONY: all test install uninstall status clean

all:
	$(MAKE) -C server BUILD_DIR="$(BUILD_DIR)" all

test:
	$(MAKE) -C server BUILD_DIR="$(BUILD_DIR)" test

install:
	$(MAKE) -C server BUILD_DIR="$(BUILD_DIR)" PREFIX="$(PREFIX)" SUDO="$(SUDO)" install

uninstall:
	$(MAKE) -C server PREFIX="$(PREFIX)" SUDO="$(SUDO)" uninstall

status:
	$(MAKE) -C server BUILD_DIR="$(BUILD_DIR)" SUDO="$(SUDO)" status

clean:
	$(MAKE) -C server BUILD_DIR="$(BUILD_DIR)" clean
