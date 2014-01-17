#!/bin/bash

set -x
set -e
set -u

HERE="$(cd $(dirname $0) && pwd)"
. ${HERE}/buildbot_functions.sh

ROOT=`pwd`
PLATFORM=`uname`
export PATH="/usr/local/bin:$PATH"

if [ "$BUILDBOT_CLOBBER" != "" ]; then
  echo @@@BUILD_STEP clobber@@@
  rm -rf llvm
  rm -rf llvm_build0
fi

# CMake does not notice that the compiler itself has changed.
# Anyway, incremental builds of stage2 and stage3 compilers don't make sense.
# Clobber the build trees.
rm -rf libcxx_build_msan
rm -rf llvm_build_msan
rm -rf llvm_build2_msan
rm -rf llvm_build_asan
rm -rf llvm_build2_asan

MAKE_JOBS=${MAX_MAKE_JOBS:-16}
LLVM=$ROOT/llvm

type -a gcc
type -a g++
CMAKE_COMMON_OPTIONS="-GNinja -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON -DGCC_INSTALL_PREFIX=$HOST_GCC_PATH"
CMAKE_STAGE1_OPTIONS="${CMAKE_COMMON_OPTIONS} -DCMAKE_C_COMPILER=$HOST_GCC_PATH/bin/gcc -DCMAKE_CXX_COMPILER=$HOST_GCC_PATH/bin/g++"

echo @@@BUILD_STEP update@@@
buildbot_update

# Stage 1

echo @@@BUILD_STEP build stage1 clang@@@
if [ ! -d llvm_build0 ]; then
  mkdir llvm_build0
fi
(cd llvm_build0 && cmake ${CMAKE_STAGE1_OPTIONS} $LLVM && \
  ninja clang && ninja compiler-rt && ninja llvm-symbolizer) || \
  echo @@@STEP_FAILURE@@@

# Stage 2 / MemorySanitizer

echo @@@BUILD_STEP build clang/msan@@@

CLANG_PATH=$ROOT/llvm_build0/bin
CMAKE_STAGE2_COMMON_OPTIONS="\
  ${CMAKE_COMMON_OPTIONS} \
  -DCMAKE_C_COMPILER=${CLANG_PATH}/clang \
  -DCMAKE_CXX_COMPILER=${CLANG_PATH}/clang++ \
  "
export ASAN_SYMBOLIZER_PATH=${CLANG_PATH}/llvm-symbolizer
export MSAN_SYMBOLIZER_PATH=${CLANG_PATH}/llvm-symbolizer
# Prebuilt libstdc++ with MSan instrumentation.
# This will break if MSan ABI is changed.
LIBSTDCXX_DIR=$ROOT/../../../libstdc++-msan-origins
CMAKE_MSAN_EXE_LINKER_FLAGS="-Wl,--rpath=${LIBSTDCXX_DIR} -L${LIBSTDCXX_DIR}"
CMAKE_MSAN_OPTIONS=" \
  ${CMAKE_STAGE2_COMMON_OPTIONS} \
  -DLLVM_USE_SANITIZER=Memory \
  "

if [ ! -d llvm_build_msan ]; then
  mkdir llvm_build_msan
fi

(cd llvm_build_msan && \
 cmake ${CMAKE_MSAN_OPTIONS} -DCMAKE_EXE_LINKER_FLAGS="${CMAKE_MSAN_EXE_LINKER_FLAGS}" $LLVM && \
 ninja clang) || echo @@@STEP_FAILURE@@@

echo @@@BUILD_STEP check-llvm msan@@@

(cd llvm_build_msan && ninja check-llvm) || echo @@@STEP_FAILURE@@@


echo @@@BUILD_STEP check-clang msan@@@

(cd llvm_build_msan && ninja check-clang) || echo @@@STEP_FAILURE@@@


# Stage 3 / MemorySanitizer

echo @@@BUILD_STEP build stage3/msan clang@@@

if [ ! -d llvm_build2_msan ]; then
  mkdir llvm_build2_msan
fi

CLANG_MSAN_PATH=$ROOT/llvm_build_msan/bin
CMAKE_STAGE3_COMMON_OPTIONS="${CMAKE_COMMON_OPTIONS}"
CMAKE_STAGE3_MSAN_OPTIONS="${CMAKE_STAGE3_COMMON_OPTIONS} -DCMAKE_C_COMPILER=${CLANG_MSAN_PATH}/clang -DCMAKE_CXX_COMPILER=${CLANG_MSAN_PATH}/clang++"

(cd llvm_build2_msan && cmake ${CMAKE_STAGE3_MSAN_OPTIONS} $LLVM && ninja) || \
  echo @@@STEP_FAILURE@@@


echo @@@BUILD_STEP check-all stage3/msan@@@

(cd llvm_build2_msan && ninja check-all) || echo @@@STEP_FAILURE@@@


# Stage 2 / AddressSanitizer

echo @@@BUILD_STEP build clang/asan@@@

# Turn on init-order checker as ASan runtime option.
export ASAN_OPTIONS="check_initialization_order=true:detect_stack_use_after_return=1:detect_leaks=1"
CMAKE_ASAN_OPTIONS=" \
  ${CMAKE_STAGE2_COMMON_OPTIONS} \
  -DLLVM_USE_SANITIZER=Address \
  "

if [ ! -d llvm_build_asan ]; then
  mkdir llvm_build_asan
fi

(cd llvm_build_asan && \
 cmake ${CMAKE_ASAN_OPTIONS} $LLVM && \
 ninja clang) || echo @@@STEP_FAILURE@@@


echo @@@BUILD_STEP check-llvm asan@@@

(cd llvm_build_asan && ninja check-llvm) || echo @@@STEP_FAILURE@@@


echo @@@BUILD_STEP check-clang asan@@@

(cd llvm_build_asan && ninja check-clang) || echo @@@STEP_FAILURE@@@


# Stage 3 / AddressSanitizer

echo @@@BUILD_STEP build stage3/asan clang@@@

if [ ! -d llvm_build2_asan ]; then
  mkdir llvm_build2_asan
fi

CLANG_ASAN_PATH=$ROOT/llvm_build_asan/bin
CMAKE_STAGE3_COMMON_OPTIONS="${CMAKE_STAGE2_COMMON_OPTIONS}"
CMAKE_STAGE3_ASAN_OPTIONS="${CMAKE_STAGE3_COMMON_OPTIONS} -DCMAKE_C_COMPILER=${CLANG_ASAN_PATH}/clang -DCMAKE_CXX_COMPILER=${CLANG_ASAN_PATH}/clang++"

(cd llvm_build2_asan && cmake ${CMAKE_STAGE3_ASAN_OPTIONS} $LLVM && ninja) || \
  echo @@@STEP_FAILURE@@@


echo @@@BUILD_STEP check-all stage3/asan@@@

(cd llvm_build2_asan && ninja check-all) || echo @@@STEP_FAILURE@@@
