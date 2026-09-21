cmake_minimum_required(VERSION 3.22.1)
project(terraformingmars LANGUAGES CXX)

# The JNI bridge (NodeRuntime.startNode) that starts the embedded Node.js.
add_library(native-lib SHARED src/main/cpp/native-lib.cpp)
target_compile_features(native-lib PRIVATE cxx_std_17)
target_include_directories(native-lib PRIVATE libnode/include/node)
# Our own library is 16 KB page aligned; the prebuilt libnode.so is not (see README).
target_link_options(native-lib PRIVATE "-Wl,-z,max-page-size=16384")

# The prebuilt nodejs-mobile runtime, unpacked by fetch-libnode.sh. Gradle
# packages an imported shared library into the APK next to native-lib.
add_library(libnode SHARED IMPORTED)
set_target_properties(libnode PROPERTIES
  IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/libnode/bin/${ANDROID_ABI}/libnode.so)

target_link_libraries(native-lib libnode log)
