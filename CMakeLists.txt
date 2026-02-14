cmake_minimum_required(VERSION 3.16)
project(Whispertype VERSION 1.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_FLAGS "${CMAKE_OBJCXX_FLAGS} -fobjc-arc")

# whisper.cpp - local submodule
set(WHISPER_DIR "${CMAKE_SOURCE_DIR}/external/whisper.cpp")

cmake_policy(SET CMP0077 NEW)

# Build whisper as static library
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)

# whisper.cpp / ggml optimizations for Apple Silicon
if(APPLE)
    set(GGML_NATIVE    ON CACHE BOOL "Auto-detect CPU features (dotprod, i8mm, fp16)" FORCE)
    set(GGML_METAL     ON CACHE BOOL "GPU acceleration via Metal" FORCE)
    set(GGML_ACCELERATE ON CACHE BOOL "AMX coprocessor via Accelerate framework" FORCE)
    set(WHISPER_COREML OFF CACHE BOOL "CoreML (requires model conversion)" FORCE)
    set(GGML_OPENMP   OFF CACHE BOOL "Apple Clang has no OpenMP" FORCE)
    set(GGML_CCACHE   OFF CACHE BOOL "Don't require ccache" FORCE)
endif()
add_subdirectory(${WHISPER_DIR} whisper.cpp)

# All source files (Objective-C++)
set(SOURCES
    src/main.mm
    src/appcontroller.mm
    src/voicerecorder.mm
    src/whispertranscriber.mm
    src/groqtranscriber.mm
    src/textinjector.mm
    src/globalhotkey.mm
    src/statusbarcontroller.mm
    src/macpermissions.mm
)

set(HEADERS
    src/appcontroller.h
    src/voicerecorder.h
    src/whispertranscriber.h
    src/groqtranscriber.h
    src/textinjector.h
    src/globalhotkey.h
    src/statusbarcontroller.h
    src/macpermissions.h
)

# Create executable
add_executable(${PROJECT_NAME} ${SOURCES} ${HEADERS})

# Include directories
target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${WHISPER_DIR}/include
)

# Link whisper
target_link_libraries(${PROJECT_NAME} PRIVATE whisper)

# macOS specific
if(APPLE)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_GUI_IDENTIFIER com.tqt.whispertype
        MACOSX_BUNDLE_BUNDLE_NAME "Whispertype"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_SOURCE_DIR}/Whispertype.entitlements"
    )

    # Copy Metal shader to bundle Resources
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:${PROJECT_NAME}>/Contents/Resources"
        COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_BINARY_DIR}/bin/ggml-metal.metal" "$<TARGET_BUNDLE_DIR:${PROJECT_NAME}>/Contents/Resources/" || true
        COMMENT "Copying Metal shader to bundle"
    )

    # Sign the bundle
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND codesign --force --sign - --entitlements "${CMAKE_SOURCE_DIR}/Whispertype.entitlements" "$<TARGET_BUNDLE_DIR:${PROJECT_NAME}>"
        COMMENT "Signing app bundle"
    )

    # Link macOS frameworks
    target_link_libraries(${PROJECT_NAME} PRIVATE
        "-framework AVFoundation"
        "-framework CoreAudio"
        "-framework AudioToolbox"
        "-framework Metal"
        "-framework MetalKit"
        "-framework Accelerate"
        "-framework Foundation"
        "-framework Cocoa"
        "-framework ApplicationServices"
        "-framework Carbon"
    )
endif()
