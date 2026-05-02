cmake_minimum_required(VERSION 3.16)
project(hidmi_server LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(PkgConfig)
pkg_check_modules(PROTOBUF_PKG protobuf)
if(NOT PROTOBUF_PKG_FOUND)
    find_package(Protobuf REQUIRED)
endif()
find_program(PROTOC_EXECUTABLE protoc REQUIRED)

file(GLOB HIDMI_PROTO_FILES CONFIGURE_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/../proto/*.proto
)
set(HIDMI_GENERATED_PROTO_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
set(HIDMI_PROTO_SOURCES)
set(HIDMI_PROTO_HEADERS)
foreach(PROTO_FILE ${HIDMI_PROTO_FILES})
    get_filename_component(PROTO_NAME ${PROTO_FILE} NAME_WE)
    list(APPEND HIDMI_PROTO_SOURCES ${HIDMI_GENERATED_PROTO_DIR}/${PROTO_NAME}.pb.cc)
    list(APPEND HIDMI_PROTO_HEADERS ${HIDMI_GENERATED_PROTO_DIR}/${PROTO_NAME}.pb.h)
endforeach()
add_custom_command(
    OUTPUT ${HIDMI_PROTO_SOURCES} ${HIDMI_PROTO_HEADERS}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${HIDMI_GENERATED_PROTO_DIR}
    COMMAND ${PROTOC_EXECUTABLE}
        -I ${CMAKE_CURRENT_SOURCE_DIR}/../proto
        --cpp_out=${HIDMI_GENERATED_PROTO_DIR}
        ${HIDMI_PROTO_FILES}
    DEPENDS ${HIDMI_PROTO_FILES}
    COMMENT "Generating C++ protobuf bindings"
    VERBATIM
)

set(HIDMI_CORE_SOURCES
    src/cli.cpp
    src/config.cpp
    src/daemon.cpp
    src/devices.cpp
    src/gadget.cpp
    src/install.cpp
    src/json.cpp
    src/status.cpp
    src/utils.cpp
    ${HIDMI_PROTO_SOURCES}
)

add_library(hidmi_core ${HIDMI_CORE_SOURCES})
target_include_directories(hidmi_core PUBLIC src ${HIDMI_GENERATED_PROTO_DIR} ${PROTOBUF_PKG_INCLUDE_DIRS} ${Protobuf_INCLUDE_DIRS})
target_compile_options(hidmi_core PRIVATE -Wall -Wextra -Wpedantic -Wno-nullability-extension)
if(PROTOBUF_PKG_FOUND)
    target_link_directories(hidmi_core PUBLIC ${PROTOBUF_PKG_LIBRARY_DIRS})
    target_link_libraries(hidmi_core PUBLIC ${PROTOBUF_PKG_LIBRARIES})
    target_link_options(hidmi_core PUBLIC ${PROTOBUF_PKG_LDFLAGS_OTHER})
else()
    target_link_libraries(hidmi_core PUBLIC protobuf::libprotobuf)
endif()

add_executable(hidmi
    src/main.cpp
)
target_link_libraries(hidmi PRIVATE hidmi_core)
target_compile_options(hidmi PRIVATE -Wall -Wextra -Wpedantic)
install(TARGETS hidmi RUNTIME DESTINATION bin)

enable_testing()
add_executable(hidmi_tests
    tests/cpp_tests.cpp
)
target_link_libraries(hidmi_tests PRIVATE hidmi_core)
target_compile_options(hidmi_tests PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME hidmi_tests COMMAND hidmi_tests)
