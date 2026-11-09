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
    echo "--- errors from $name log:" >> "$RESULTS/summary.md"
    grep -B1 -A5 -m 8 -iE "CMake Error|error:|Error opening|failed|FATAL" "$ROOT/logs/$name.log" >> "$RESULTS/summary.md" || true
    echo "--- tail of $name log:" >> "$RESULTS/summary.md"
    tail -20 "$ROOT/logs/$name.log" >> "$RESULTS/summary.md"
  fi
}

CMAKE_IOS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$SYSROOT" -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

cmake_dep() {
  local name="$1" src="$2"; shift 2
  cmake -S "$src" -B "$ROOT/build/$name/b" "${CMAKE_IOS[@]}" "$@" &&
  cmake --build "$ROOT/build/$name/b" -j"$JOBS" &&
  cmake --install "$ROOT/build/$name/b"
}

# ---------- media / support libs OSG needs ----------
freetype() {
  curl -L -o "$ROOT/build/ft.tar.gz" https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-2.tar.gz &&
  tar xzf "$ROOT/build/ft.tar.gz" -C "$ROOT/build" &&
  cmake_dep freetype "$ROOT/build/freetype-VER-2-13-2" -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON -DBUILD_SHARED_LIBS=OFF
}

libpng() {
  git clone --depth 1 https://github.com/pnggroup/libpng.git "$ROOT/build/libpng" &&
  cmake_dep libpng "$ROOT/build/libpng" -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_FRAMEWORK=OFF -DPNG_TOOLS=OFF &&
  cp "$SYSROOT/include/libpng18/"*.h "$SYSROOT/include/" 2>/dev/null || true
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
  # Recipe: research notes SS3 - ICU 70.1 (the version OpenMW 0.51 pins).
  # Host build (native, tools ENABLED - the cross build runs them) in-source,
  # then a separate cross build dir with --with-cross-build=<host source dir>.
  cd "$ROOT/build" &&
  curl -L -o icu.zip https://github.com/unicode-org/icu/archive/refs/tags/release-70-1.zip &&
  unzip -q icu.zip &&
  curl -L -o icufilters.json https://raw.githubusercontent.com/OpenMW/openmw/openmw-51/extern/icufilters.json &&
  cd icu-release-70-1/icu4c/source &&
  ./configure --disable-tests --disable-samples --disable-icuio --disable-extras &&
  make -j"$JOBS" &&
  cd "$ROOT/build" && mkdir -p icu-cross && cd icu-cross &&
  env CC="clang -target arm64-apple-ios15.0 -isysroot $SDK" \
      CXX="clang++ -target arm64-apple-ios15.0 -isysroot $SDK" \
      AR="$(xcrun -sdk iphoneos -find ar)" RANLIB="$(xcrun -sdk iphoneos -find ranlib)" \
      ICU_DATA_FILTER_FILE="$ROOT/build/icufilters.json" \
      "$ROOT/build/icu-release-70-1/icu4c/source/configure" \
      --host=aarch64-apple-darwin \
      --with-cross-build="$ROOT/build/icu-release-70-1/icu4c/source" \
      --enable-static --disable-shared \
      --disable-tests --disable-samples --disable-icuio --disable-extras --disable-tools \
      --prefix="$SYSROOT" &&
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
  cmake_dep Bullet "$ROOT/build/bullet" -DBUILD_UNIT_TESTS=OFF -DBUILD_BULLET2_DEMOS=OFF -DBUILD_CPU_DEMOS=OFF -DBUILD_EXTRAS=OFF -DBUILD_OPENGL3_DEMOS=OFF -DINSTALL_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DUSE_DOUBLE_PRECISION=ON
}

yamlcpp() {
  git clone --depth 1 --branch 0.8.0 https://github.com/jbeder/yaml-cpp.git "$ROOT/build/yaml-cpp" &&
  cmake_dep yaml-cpp "$ROOT/build/yaml-cpp" -DYAML_BUILD_SHARED_LIBS=OFF -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF
}

boost() {
  # Real Boost.Build route: OpenMW 0.51 does find_package(Boost CONFIG REQUIRED
  # COMPONENTS iostreams program_options) - it needs proper CMake config files,
  # which only a b2 install generates. (Research notes SS0/SS2.1.)
  cd "$ROOT/build" &&
  curl -L -o boost.tar.bz2 https://archives.boost.org/release/1.85.0/source/boost_1_85_0.tar.bz2 &&
  tar xjf boost.tar.bz2 &&
  cd boost_1_85_0 &&
  ./bootstrap.sh &&
  cat > "$ROOT/build/user-config.jam" <<JAM
using clang : ios : /usr/bin/clang++ : <archiver>/usr/bin/ar <ranlib>/usr/bin/ranlib ;
JAM
  HOME="$ROOT/build" ./b2 -j"$JOBS" --user-config="$ROOT/build/user-config.jam" \
    toolset=clang-ios target-os=iphone architecture=arm address-model=64 \
    variant=release threading=multi link=static runtime-link=static \
    cflags="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0" \
    cxxflags="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -std=c++17" \
    linkflags="-arch arm64 -isysroot $SDK" \
    --with-iostreams --with-program_options --prefix="$SYSROOT" install &&
  {
    # Round 8 fix: a b2 install limited to --with-iostreams/--with-program_options
    # does NOT ship the boost_headers CMake config package, but BoostConfig.cmake
    # requires it first and unconditionally:
    #   find_package(boost_headers 1.85.0 EXACT CONFIG HINTS <sysroot>/lib/cmake)
    # (verified in the pinned boostorg/cmake BoostConfig.cmake for 1.85.0).
    # Run 7 died exactly there. If the config is missing, write a minimal one
    # defining the Boost::headers INTERFACE target, plus an exact-version file.
    echo "--- boost cmake dirs after b2 install:"
    ls "$SYSROOT/lib/cmake" 2>/dev/null || true
    BH_DIR="$SYSROOT/lib/cmake/boost_headers-1.85.0"
    if [ ! -f "$BH_DIR/boost_headers-config.cmake" ]; then
      echo "boost_headers config missing - generating minimal package in $BH_DIR"
      mkdir -p "$BH_DIR"
      cat > "$BH_DIR/boost_headers-config.cmake" <<'CMAKEEOF'
# Minimal boost_headers package - generated by deps/build-all.sh because a
# limited b2 install does not ship it. Defines Boost::headers only.
get_filename_component(_BOOST_INCLUDEDIR "${CMAKE_CURRENT_LIST_DIR}/../../../include" ABSOLUTE)
if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  set_target_properties(Boost::headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_BOOST_INCLUDEDIR}")
endif()
set(boost_headers_VERSION "1.85.0")
CMAKEEOF
      cat > "$BH_DIR/boost_headers-config-version.cmake" <<'CMAKEEOF'
set(PACKAGE_VERSION "1.85.0")
set(PACKAGE_VERSION_UNSUITABLE FALSE)
set(PACKAGE_VERSION_COMPATIBLE FALSE)
set(PACKAGE_VERSION_EXACT FALSE)
if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  set(PACKAGE_VERSION_EXACT TRUE)
elseif(NOT PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
CMAKEEOF
    fi
    ls "$SYSROOT/lib/cmake"
  }
}

lua51() {
  # Round 10 fix: Run 9 died here - www.lua.org did not accept a connection
  # from the runner for 75s (curl 28), so liblua.a and the lua5.1 headers
  # never landed and engine configure then failed with
  # "Could NOT find Lua (missing: LUA_INCLUDE_DIR)". lua.org is
  # intermittently slow from the runners (Run 8 took 70s for this same
  # download; Runs 5-7 took 3-8s). Retry lua.org with a bounded connect
  # timeout, then fall back to the Debian orig tarball, which is
  # byte-identical to the lua.org tarball (md5
  # 2e115fe26e435e33b0d5c022e4490567, the published lua-5.1.5.tar.gz md5,
  # verified locally Nov 9) and extracts to the same lua-5.1.5/src layout,
  # so nothing downstream changes.
  cd "$ROOT/build" &&
  { curl -fL --retry 2 --retry-all-errors --connect-timeout 30 --max-time 240 -o lua.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz ||
    curl -fL --retry 3 --retry-all-errors --connect-timeout 30 --max-time 240 -o lua.tar.gz https://deb.debian.org/debian/pool/main/l/lua5.1/lua5.1_5.1.5.orig.tar.gz; } &&
  tar xzf lua.tar.gz &&
  cd lua-5.1.5/src &&
  sed -i.bak 's/system(luaL_optstring(L, 1, NULL))/0/' loslib.c &&
  for f in ./*.c; do
    case "$f" in ./lua.c|./luac.c|./print.c) ;; *)
      clang -O2 -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -DLUA_USE_POSIX -c "$f" || return 1 ;;
    esac
  done &&
  ar rcs "$SYSROOT/lib/liblua.a" ./*.o &&
  mkdir -p "$SYSROOT/include/lua5.1" "$SYSROOT/include/lua" &&
  cp lua.h lauxlib.h lualib.h luaconf.h "$SYSROOT/include/lua5.1/" &&
  cp lua.h lauxlib.h lualib.h luaconf.h "$SYSROOT/include/lua/" &&
  ( cp lua.hpp "$SYSROOT/include/lua5.1/" 2>/dev/null || cp ../etc/lua.hpp "$SYSROOT/include/lua5.1/" ) &&
  ( cp lua.hpp "$SYSROOT/include/lua/" 2>/dev/null || cp ../etc/lua.hpp "$SYSROOT/include/lua/" )
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

shims() {
  # GLES header shims: the OSG fork's GLES3 profile includes <GLES3/gl3.h>;
  # iOS names it <OpenGLES/ES3/gl.h>. Provide forwarding headers in the sysroot.
  mkdir -p "$SYSROOT/include/GLES3" "$SYSROOT/include/GLES2"
  printf '#pragma once\n#include <OpenGLES/ES3/gl.h>\n' > "$SYSROOT/include/GLES3/gl3.h"
  printf '#pragma once\n#include <OpenGLES/ES3/glext.h>\n' > "$SYSROOT/include/GLES3/gl3ext.h"
  printf '#pragma once\n#include <OpenGLES/ES3/gl.h>\n' > "$SYSROOT/include/GLES3/gl32.h"
  printf '#pragma once\n#include <OpenGLES/ES2/gl.h>\n' > "$SYSROOT/include/GLES2/gl2.h"
  printf '#pragma once\n#include <OpenGLES/ES2/glext.h>\n' > "$SYSROOT/include/GLES2/gl2ext.h"
  # Round 12 fix: Run 11 engine configure died on OpenGL. There is no
  # OpenGL.framework in the iPhone SDK (only OpenGLES.framework), so
  # find_package(OpenGL REQUIRED) in OpenMW's top level cannot succeed
  # from the SDK, and OSG's non-iPhone branch UNSETs the seeded
  # OPENGL_gl_LIBRARY / OPENGL_INCLUDE_DIR cache vars and re-searches,
  # failing again (its feature_summary lists OpenGL as REQUIRED not
  # found). Provide a real shim OpenGL.framework in the sysroot whose
  # headers forward to OpenGLES ES3 and whose binary is a copy of the
  # SDK's OpenGLES stub/binary (its install name already points at the
  # real OpenGLES.framework, so linking the shim links OpenGLES), plus
  # a plain OpenGL/gl.h header tree under include/ so find_path for
  # OpenGL/gl.h also succeeds outside framework-only search.
  mkdir -p "$SYSROOT/include/OpenGL" "$SYSROOT/frameworks/OpenGL.framework/Headers"
  printf '#pragma once\n#include <OpenGLES/ES3/gl.h>\n' > "$SYSROOT/include/OpenGL/gl.h"
  printf '#pragma once\n#include <OpenGLES/ES3/gl.h>\n' > "$SYSROOT/include/OpenGL/gl3.h"
  printf '#pragma once\n#include <OpenGLES/ES3/gl.h>\n' > "$SYSROOT/frameworks/OpenGL.framework/Headers/gl.h"
  printf '#pragma once\n#include <OpenGLES/ES3/gl.h>\n' > "$SYSROOT/frameworks/OpenGL.framework/Headers/gl3.h"
  printf '#pragma once\n#include <OpenGLES/ES3/glext.h>\n' > "$SYSROOT/frameworks/OpenGL.framework/Headers/glext.h"
  GLES_FW="$SDK/System/Library/Frameworks/OpenGLES.framework"
  if [ -e "$GLES_FW/OpenGLES" ]; then
    cp -Lf "$GLES_FW/OpenGLES" "$SYSROOT/frameworks/OpenGL.framework/OpenGL" || true
  elif [ -e "$GLES_FW/OpenGLES.tbd" ]; then
    cp -Lf "$GLES_FW/OpenGLES.tbd" "$SYSROOT/frameworks/OpenGL.framework/OpenGL" || true
  fi
  cat > "$SYSROOT/frameworks/OpenGL.framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>OpenGL</string>
  <key>CFBundleIdentifier</key><string>com.apple.OpenGL</string>
  <key>CFBundleName</key><string>OpenGL</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
</dict>
</plist>
PLIST
  true
}

echo "## All deps (hardest first)" >> "$RESULTS/summary.md"
build_dep Shims shims
build_dep FreeType freetype
build_dep libpng libpng
build_dep libjpeg libjpeg
build_dep ICU icu
build_dep FFmpeg ffmpeg
build_dep SDL2 sdl2
build_dep LZ4 lz4
build_dep Boost boost
build_dep Lua51 lua51
# OSG, Bullet, yaml-cpp, MyGUI, SQLite3, Recast: built by the engine's own
# extern FetchContent (upstream-pinned recipes) - see ci/run.sh USE_SYSTEM flags.
build_dep OpenAL openal
du -sh "$SYSROOT" >> "$RESULTS/summary.md"
echo "build-all done"
