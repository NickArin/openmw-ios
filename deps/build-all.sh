#!/bin/bash
# FULL dependency build for the OpenMW iOS port (Arin's full-throttle call, Nov 8 2026).
# Every dep cross-compiles static for iphoneos/arm64 into ./sysroot.
# Hardest deps first; each dep is independent - a failure logs and the run continues,
# so one CI run returns the maximum information.
set -u
ROOT="$(pwd)"
SYSROOT="$ROOT/sysroot"
RESULTS="$ROOT/results"
mkdir -p "$SYSROOT/lib" "$SYSROOT/include" "$RESULTS" "$ROOT/logs" "$ROOT/build"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
echo "SDK: $SDK, jobs: $JOBS" >> "$RESULTS/summary.md"

build_dep() {
  local name="$1"; shift
  local start=$SECONDS
  echo "=== $name $(date +%T)"
  if "$@" > "$ROOT/logs/$name.log" 2>&1; then
    echo "- $name: OK ($((SECONDS-start))s)" >> "$RESULTS/summary.md"
  else
    echo "- $name: FAIL ($((SECONDS-start))s)" >> "$RESULTS/summary.md"
    echo "--- tail of $name log:" >> "$RESULTS/summary.md"
    tail -30 "$ROOT/logs/$name.log" >> "$RESULTS/summary.md"
  fi
}

CMAKE_IOS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$SYSROOT")

cmake_dep() {
  local name="$1" src="$2"; shift 2
  cmake -S "$src" -B "$ROOT/build/$name/b" "${CMAKE_IOS[@]}" "$@" &&
  cmake --build "$ROOT/build/$name/b" -j"$JOBS" &&
  cmake --install "$ROOT/build/$name/b"
}

# ---------- media / support libs OSG needs ----------
freetype() {
  curl -L -o "$ROOT/build/ft.tar.gz" https://gitlab.freedesktop.org/freetype/freetype/-/archive/FT-2-13-2/freetype-FT-2-13-2.tar.gz &&
  tar xzf "$ROOT/build/ft.tar.gz" -C "$ROOT/build" &&
  cmake_dep freetype "$ROOT/build/freetype-FT-2-13-2" -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON -DBUILD_SHARED_LIBS=OFF
}

libpng() {
  git clone --depth 1 https://github.com/pnggroup/libpng.git "$ROOT/build/libpng" &&
  cmake_dep libpng "$ROOT/build/libpng" -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_FRAMEWORK=OFF -DPNG_TOOLS=OFF
}

libjpeg() {
  git clone --depth 1 --branch 3.0.3 https://github.com/libjpeg-turbo/libjpeg-turbo.git "$ROOT/build/libjpeg" &&
  cmake_dep libjpeg "$ROOT/build/libjpeg" -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF
}

# ---------- the big three ----------
osg() {
  git clone --depth 1 https://github.com/OpenMW/osg.git "$ROOT/build/osg" &&
  cmake_dep osg "$ROOT/build/osg" \
    -DOPENGL_PROFILE=GLES3 \
    -DOSG_GL1_AVAILABLE=OFF -DOSG_GL2_AVAILABLE=OFF -DOSG_GL3_AVAILABLE=OFF \
    -DOSG_GLES1_AVAILABLE=OFF -DOSG_GLES2_AVAILABLE=OFF -DOSG_GLES3_AVAILABLE=ON \
    -DOSG_GL_DISPLAYLISTS_AVAILABLE=OFF -DOSG_GL_FIXED_FUNCTION_AVAILABLE=OFF \
    -DOSG_GL_MATRICES_AVAILABLE=OFF -DOSG_GL_VERTEX_ARRAY_FUNCS_AVAILABLE=OFF \
    -DOSG_WINDOWING_SYSTEM=IOS \
    -DDYNAMIC_OPENTHREADS=OFF -DDYNAMIC_OSG=OFF \
    -DOSG_BUILD_OSG_APPLICATIONS=OFF -DOSG_BUILD_EXAMPLES=OFF -DOSG_BUILD_DOCUMENTATION=OFF -DOSG_BUILD_FRAMEWORKS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON -DCMAKE_DISABLE_FIND_PACKAGE_GDAL=ON -DCMAKE_DISABLE_FIND_PACKAGE_GTA=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_DCMTK=ON -DCMAKE_DISABLE_FIND_PACKAGE_FFmpeg=ON -DCMAKE_DISABLE_FIND_PACKAGE_Jasper=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenEXR=ON -DCMAKE_DISABLE_FIND_PACKAGE_Collada=ON -DBUILD_SHARED_LIBS=OFF
}

icu() {
  cd "$ROOT/build" &&
  curl -L -o icu.tgz https://github.com/unicode-org/icu/releases/download/release-75-1/icu4c-75_1-src.tgz &&
  tar xzf icu.tgz &&
  mkdir -p icu-host icu-cross &&
  cd icu-host &&
  ../icu/source/runConfigureICU MacOSX --prefix="$ROOT/build/icu-host-install" &&
  make -j"$JOBS" &&
  cd ../icu-cross &&
  env CC="$(xcrun -sdk iphoneos -f clang) -arch arm64 -isysroot $SDK -miphoneos-version-min=15.0" \
      CXX="$(xcrun -sdk iphoneos -f clang++) -arch arm64 -isysroot $SDK -miphoneos-version-min=15.0" \
      ../icu/source/configure --host=arm-apple-darwin --with-cross-build="$ROOT/build/icu-host" \
      --enable-static --disable-shared --disable-samples --disable-tests --prefix="$SYSROOT" &&
  make -j"$JOBS" &&
  make install
}

ffmpeg() {
  cd "$ROOT/build" &&
  curl -L -o ffmpeg.tar.xz https://ffmpeg.org/releases/ffmpeg-6.1.2.tar.xz &&
  tar xJf ffmpeg.tar.xz &&
  cd ffmpeg-6.1.2 &&
  ./configure --prefix="$SYSROOT" --enable-cross-compile --target-os=darwin --arch=arm64 \
    --cc="clang" --cxx="clang++" \
    --extra-cflags="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0" \
    --extra-cxxflags="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0" \
    --extra-ldflags="-arch arm64 -isysroot $SDK" \
    --sysroot="$SDK" \
    --disable-programs --disable-doc --disable-debug --disable-network \
    --disable-shared --enable-static --enable-pic \
    --disable-videotoolbox --disable-audiotoolbox &&
  make -j"$JOBS" &&
  make install
}

# ---------- the rest ----------
sdl2() {
  ( git clone --depth 1 --branch release-2.32.x https://github.com/libsdl-org/SDL.git "$ROOT/build/SDL" ||
    git clone --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL.git "$ROOT/build/SDL" ) &&
  cmake_dep SDL2 "$ROOT/build/SDL" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_TESTS=OFF
}

lz4() {
  git clone --depth 1 --branch v1.10.0 https://github.com/lz4/lz4.git "$ROOT/build/lz4" &&
  cmake_dep LZ4 "$ROOT/build/lz4/build/cmake" -DBUILD_SHARED_LIBS=OFF -DLZ4_BUILD_CLI=OFF
}

bullet() {
  git clone --depth 1 --branch 3.25 https://github.com/bulletphysics/bullet3.git "$ROOT/build/bullet" &&
  cmake_dep Bullet "$ROOT/build/bullet" -DBUILD_UNIT_TESTS=OFF -DBUILD_BULLET2_DEMOS=OFF -DBUILD_CPU_DEMOS=OFF -DBUILD_EXTRAS=OFF -DBUILD_OPENGL3_DEMOS=OFF -DINSTALL_LIBS=ON -DBUILD_SHARED_LIBS=OFF
}

yamlcpp() {
  git clone --depth 1 --branch 0.8.0 https://github.com/jbeder/yaml-cpp.git "$ROOT/build/yaml-cpp" &&
  cmake_dep yaml-cpp "$ROOT/build/yaml-cpp" -DYAML_BUILD_SHARED_LIBS=OFF -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF
}

boost() {
  cd "$ROOT/build" &&
  curl -L -o boost.tar.bz2 https://archives.boost.org/release/1.85.0/source/boost_1_85_0.tar.bz2 &&
  tar xjf boost.tar.bz2 &&
  cp -R boost_1_85_0/boost "$SYSROOT/include/" &&
  cd boost_1_85_0/libs/iostreams/src &&
  clang++ -std=c++17 -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -I"$ROOT/build/boost_1_85_0" \
    -c file_descriptor.cpp mapped_file.cpp zlib.cpp gzip.cpp &&
  ar rcs "$SYSROOT/lib/libboost_iostreams.a" ./*.o
}

lua51() {
  cd "$ROOT/build" &&
  curl -L -o lua.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz &&
  tar xzf lua.tar.gz &&
  cd lua-5.1.5/src &&
  for f in ./*.c; do
    case "$f" in ./lua.c|./luac.c|./print.c) ;; *)
      clang -O2 -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -DLUA_USE_POSIX -c "$f" || return 1 ;;
    esac
  done &&
  ar rcs "$SYSROOT/lib/liblua.a" ./*.o &&
  mkdir -p "$SYSROOT/include/lua5.1" "$SYSROOT/include/lua" &&
  cp lua.h lauxlib.h lualib.h luaconf.h lua.hpp "$SYSROOT/include/lua5.1/" &&
  cp lua.h lauxlib.h lualib.h luaconf.h lua.hpp "$SYSROOT/include/lua/"
}

mygui() {
  git clone --depth 1 --branch MyGUI3.4.3 https://github.com/MyGUI/mygui.git "$ROOT/build/mygui" &&
  cmake_dep MyGUI "$ROOT/build/mygui" -DMYGUI_BUILD_DEMOS=OFF -DMYGUI_BUILD_TOOLS=OFF -DMYGUI_BUILD_PLUGINS=OFF \
    -DMYGUI_USE_FREETYPE=ON -DMYGUI_RENDERSYSTEM=1 -DBUILD_SHARED_LIBS=OFF
}

openal() {
  git clone --depth 1 --branch 1.23.1 https://github.com/kcat/openal-soft.git "$ROOT/build/openal" &&
  cmake_dep OpenAL "$ROOT/build/openal" -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
}

echo "## All deps (hardest first)" >> "$RESULTS/summary.md"
build_dep FreeType freetype
build_dep libpng libpng
build_dep libjpeg libjpeg
build_dep OSG osg
build_dep ICU icu
build_dep FFmpeg ffmpeg
build_dep SDL2 sdl2
build_dep LZ4 lz4
build_dep Bullet bullet
build_dep yaml-cpp yamlcpp
build_dep Boost boost
build_dep Lua51 lua51
build_dep MyGUI mygui
build_dep OpenAL openal
du -sh "$SYSROOT" >> "$RESULTS/summary.md"
echo "build-all done"
