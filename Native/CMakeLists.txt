cmake_minimum_required(VERSION 3.20)
project(LocalCaptionInference LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_BUILD_WITH_INSTALL_RPATH ON)
set(CMAKE_INSTALL_RPATH "@loader_path")
add_library(caption_inference SHARED Inference.mm NLLB.cpp)
target_compile_options(caption_inference PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(caption_inference PRIVATE
    ../Sources/CInference
    ../.deps/whisper/include
    ../.deps/whisper/ggml/include
    ../.deps/sentencepiece/src
    ../.deps/onnxruntime/include
    ../.deps/ctranslate2/include)
target_link_directories(caption_inference PRIVATE
    ../.deps/whisper-build/src
    ../.deps/whisper-build/ggml/src
    ../.deps/whisper-build/ggml/src/ggml-metal
    ../.deps/whisper-build/ggml/src/ggml-blas
    ../.deps/sp-build/src
    ../.deps/onnxruntime/lib)
target_link_libraries(caption_inference PRIVATE
    whisper ggml ggml-cpu ggml-blas ggml-metal ggml-base sentencepiece onnxruntime
    "${CMAKE_CURRENT_SOURCE_DIR}/../.deps/native/libctranslate2.4.6.3.dylib"
    "-framework Foundation" "-framework Accelerate" "-framework Metal" "-framework MetalKit")
