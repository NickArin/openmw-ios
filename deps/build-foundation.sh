#!/bin/bash
# Foundation deps for the OpenMW iOS build: SDL2, LZ4, Bullet, yaml-cpp.
# Cross-compiles static libs for iphoneos/arm64 into ./sysroot.
# Per-dep status + logs land in ./results/ for the workflow to publish.
set -u
ROOT="$(pwd)"
SYSROOT="$ROOT/sysroot"
RESULTS="$ROOT/results"
mkdir -p "$SYSROOT" "$RESULTS" "$ROOT/logs" "$ROOT/build"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK" >> "$RESULTS/summary.md"

build_dep() {
  local name="$1"; shift
  echo "=== $name $(date +%T)"
  if "$@" > "$ROOT/logs/$name.log" 2>&1; then
    echo "- $name: OK" >> "$RESULTS/summary.md"
  else
    echo "- $name: FAIL" >> "$RESULTS/summary.md"
    echo "--- tail of $name log:" >> "$RESULTS/summary.md"
    tail -30 "$ROOT/logs/$name.log" >> "$RESULTS/summary.md"
  fi
}

CMAKE_IOS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_BUILD_TYPE=Release)

sdl2() {
  git clone --depth 1 --branch release-2.32.x https://github.com/libsdl-org/SDL.git "$ROOT/build/SDL" &&
  cmake -S "$ROOT/build/SDL" -B "$ROOT/build/SDL/b" "${CMAKE_IOS[@]}" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF &&
  cmake --build "$ROOT/build/SDL/b" -j4 &&
  cmake --install "$ROOT/build/SDL/b"
}

lz4() {
  git clone --depth 1 --branch v1.10.0 https://github.com/lz4/lz4.git "$ROOT/build/lz4" &&
  cmake -S "$ROOT/build/lz4/build/cmake" -B "$ROOT/build/lz4/b" "${CMAKE_IOS[@]}" -DBUILD_SHARED_LIBS=OFF -DLZ4_BUILD_CLI=OFF &&
  cmake --build "$ROOT/build/lz4/b" -j4 &&
  cmake --install "$ROOT/build/lz4/b"
}

bullet() {
  git clone --depth 1 --branch 3.25 https://github.com/bulletphysics/bullet3.git "$ROOT/build/bullet" &&
  cmake -S "$ROOT/build/bullet" -B "$ROOT/build/bullet/b" "${CMAKE_IOS[@]}" -DBUILD_UNIT_TESTS=OFF -DBUILD_BULLET2_DEMOS=OFF -DBUILD_CPU_DEMOS=OFF -DBUILD_EXTRAS=OFF -DBUILD_OPENGL3_DEMOS=OFF -DINSTALL_LIBS=ON -DBUILD_SHARED_LIBS=OFF &&
  cmake --build "$ROOT/build/bullet/b" -j4 &&
  cmake --install "$ROOT/build/bullet/b"
}

yamlcpp() {
  git clone --depth 1 --branch 0.8.0 https://github.com/jbeder/yaml-cpp.git "$ROOT/build/yaml-cpp" &&
  cmake -S "$ROOT/build/yaml-cpp" -B "$ROOT/build/yaml-cpp/b" "${CMAKE_IOS[@]}" -DYAML_BUILD_SHARED_LIBS=OFF -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF &&
  cmake --build "$ROOT/build/yaml-cpp/b" -j4 &&
  cmake --install "$ROOT/build/yaml-cpp/b"
}

echo "## Foundation deps" >> "$RESULTS/summary.md"
build_dep SDL2 sdl2
build_dep LZ4 lz4
build_dep Bullet bullet
build_dep yaml-cpp yamlcpp
du -sh "$SYSROOT" >> "$RESULTS/summary.md"
find "$SYSROOT" -name "*.a" | sort >> "$RESULTS/libs.txt" || true
echo "foundation done"
