CXX ?= c++
BUILD_DIR ?= ../build/server
PREFIX ?= /usr/local
SUDO ?= sudo
CXXFLAGS ?= -std=c++17 -O2 -pthread -Wall -Wextra -Wpedantic -Wno-nullability-extension
PROTOBUF_CFLAGS ?= $(shell pkg-config --cflags protobuf 2>/dev/null)
PROTOBUF_LIBS ?= $(shell pkg-config --libs protobuf 2>/dev/null || echo -lprotobuf)
PROTOC ?= protoc
PROTO_DIR ?= ../proto
GENERATED_PROTO_DIR := $(BUILD_DIR)/generated-src
CPPFLAGS ?= -I src -I $(GENERATED_PROTO_DIR) $(PROTOBUF_CFLAGS)
INSTALL ?= install
SERVER_SOURCES := \
	src/cli.cpp \
	src/config.cpp \
	src/daemon.cpp \
	src/devices.cpp \
	src/gadget.cpp \
	src/install.cpp \
	src/json.cpp \
	src/status.cpp \
	src/utils.cpp
PROTO_FILES := $(sort $(wildcard $(PROTO_DIR)/*.proto))
PROTO_NAMES := $(basename $(notdir $(PROTO_FILES)))
PROTO_SOURCES := $(addprefix $(GENERATED_PROTO_DIR)/,$(addsuffix .pb.cc,$(PROTO_NAMES)))
PROTO_HEADERS := $(addprefix $(GENERATED_PROTO_DIR)/,$(addsuffix .pb.h,$(PROTO_NAMES)))
PROTO_STAMP := $(GENERATED_PROTO_DIR)/.generated.stamp
SERVER_HEADERS := src/hidmi.hpp src/hidmi_internal.hpp
SERVER_OBJECTS := $(patsubst src/%.cpp,$(BUILD_DIR)/%.o,$(SERVER_SOURCES))
PROTO_OBJECTS := $(patsubst $(GENERATED_PROTO_DIR)/%.pb.cc,$(BUILD_DIR)/generated/%.pb.o,$(PROTO_SOURCES))
MAIN_OBJECT := $(BUILD_DIR)/main.o
TEST_OBJECT := $(BUILD_DIR)/cpp_tests.o

.PHONY: all test install uninstall status clean
.SECONDARY: $(PROTO_SOURCES) $(PROTO_HEADERS)

all: $(BUILD_DIR)/hidmi

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: src/%.cpp $(SERVER_HEADERS) | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(SERVER_OBJECTS): $(PROTO_STAMP)

$(PROTO_STAMP): $(PROTO_FILES) | $(BUILD_DIR)
	mkdir -p $(GENERATED_PROTO_DIR)
	$(PROTOC) -I $(PROTO_DIR) --cpp_out=$(GENERATED_PROTO_DIR) $(PROTO_FILES)
	touch $@

$(GENERATED_PROTO_DIR)/%.pb.cc $(GENERATED_PROTO_DIR)/%.pb.h: $(PROTO_STAMP)
	@true

$(BUILD_DIR)/generated/%.pb.o: $(GENERATED_PROTO_DIR)/%.pb.cc $(GENERATED_PROTO_DIR)/%.pb.h | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/generated
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(TEST_OBJECT): tests/cpp_tests.cpp $(SERVER_HEADERS) $(PROTO_STAMP) | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/hidmi: $(SERVER_OBJECTS) $(PROTO_OBJECTS) $(MAIN_OBJECT)
	$(CXX) $(CXXFLAGS) $^ $(PROTOBUF_LIBS) -o $@

$(BUILD_DIR)/hidmi_tests: $(SERVER_OBJECTS) $(PROTO_OBJECTS) $(TEST_OBJECT)
	$(CXX) $(CXXFLAGS) $^ $(PROTOBUF_LIBS) -o $@

test: $(BUILD_DIR)/hidmi_tests
	$(BUILD_DIR)/hidmi_tests

install: $(BUILD_DIR)/hidmi
	$(SUDO) $(INSTALL) -d "$(PREFIX)/bin"
	$(SUDO) $(INSTALL) -m 0755 "$(BUILD_DIR)/hidmi" "$(PREFIX)/bin/hidmi"

uninstall:
	$(SUDO) rm -f "$(PREFIX)/bin/hidmi"

status:
	$(SUDO) hidmi status

clean:
	rm -rf $(BUILD_DIR)
