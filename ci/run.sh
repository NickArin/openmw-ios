#!/bin/bash
# retrigger: run 15's first workflow died before posting results (07:20 PST notice, no issue) - nudge commit 2026-11-09 per Arin
# CI stage runner (called by the thin workflow). FULL pipeline: all deps -> engine -> unsigned IPA.
# Writes results/summary.md + results/libs.txt for the workflow to publish as an issue.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SYSROOT="$ROOT/sysroot"
mkdir -p results logs build
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
{
  echo "## Runner environment"
  echo "- date: $(date)"
  echo "- runner: $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m), $(sysctl -n machdep.cpu.brand_string)"
  echo "- xcode: $(xcodebuild -version | head -1)"
  echo "- iphoneos SDK: $SDK"
  echo "- disk free: $(df -h . | tail -1 | awk '{print $4}')"
} >> results/summary.md

bash deps/build-all.sh

# ================= OpenMW engine =================
echo "## OpenMW engine" >> results/summary.md
CMAKE_IOS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$SYSROOT" -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

if git clone --depth 1 --branch openmw-51 https://github.com/OpenMW/openmw.git build/openmw > logs/clone-openmw.log 2>&1; then
  GEN="Unix Makefiles"; command -v ninja >/dev/null && GEN="Ninja"
  OPENAL_LIB="$(find "$SYSROOT" -iname "libopenal*" \( -name "*.a" -o -name "*.dylib" \) 2>/dev/null | head -1)"
  [ -z "$OPENAL_LIB" ] && OPENAL_LIB="$(find "$SYSROOT" -iname "OpenAL.framework" -type d 2>/dev/null | head -1)"
  echo "- generator: $GEN; openal lib: ${OPENAL_LIB:-NOT FOUND}" >> results/summary.md
  # Round 8 insurance: if deps did not leave a boost_headers config package,
  # generate the minimal one here too (BoostConfig.cmake requires it first).
  BH_DIR="$SYSROOT/lib/cmake/boost_headers-1.85.0"
  if [ ! -f "$BH_DIR/boost_headers-config.cmake" ]; then
    mkdir -p "$BH_DIR"
    cat > "$BH_DIR/boost_headers-config.cmake" <<'CMAKEEOF'
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
    echo "- boost_headers config: generated fallback in ci/run.sh" >> results/summary.md
  fi
  # Round 9 fix: Run 7 failed on boost_headers and Run 8 on boost_iostreams
  # with the same signature - BoostConfig.cmake's nested
  # find_package(boost_<comp> ... HINTS <sysroot>/lib/cmake) cannot discover
  # component config packages under the iOS find-root rules, even though the
  # files exist in the sysroot (Run 8 inventory lists them). The one
  # component that passed in Run 8, boost_headers, is the one whose _DIR was
  # seeded below. Seed every remaining component OpenMW requests
  # (iostreams, program_options; their only Boost dependency is headers,
  # already seeded) and set CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH so any
  # nested config search also sees the real sysroot paths.
  # Boost_USE_STATIC_LIBS / Boost_USE_STATIC_RUNTIME match the b2 build
  # (link=static runtime-link=static in deps/build-all.sh) so the
  # b2-generated variant files are not rejected as unsuitable.
  # Round 10 fix: Run 10 cleared every dep (Lua51 and OpenAL included) and
  # engine configure then died in cmake/CheckLuaCustomAllocator.cmake -
  # try_run() cannot run an iOS binary on the macOS runner in
  # cross-compiling mode, and CMake errors unless the run-result cache
  # variable is preset. That file literally names its result variable
  # RUN_RESULT_VAR. Preset it to 0: plain Lua 5.1 lua_newstate() takes a
  # custom lua_Alloc by design (that is its core API), so 0 (success) is
  # the truthful result; the compile half of try_run still runs for real.
  # Round 12 fix: Run 11 cleared every dep, then engine configure died
  # with REQUIRED package OpenGL not found (see deps/build-all.sh shims
  # for the shim OpenGL.framework that now also ships in the sysroot).
  # Two more pieces are needed here:
  # (1) OSG must take its iPhone branch. Without OSG_BUILD_PLATFORM_IPHONE
  # the pinned OSG fork treats this as a macOS build: it UNSETs the
  # seeded OPENGL_gl_LIBRARY / OPENGL_INCLUDE_DIR cache vars, calls
  # find_package(OpenGL) again (no OpenGL.framework exists in the
  # iPhone SDK, so it fails), and defaults OSG_WINDOWING_SYSTEM to
  # Cocoa, which also cannot build against the iPhone SDK. Its iPhone
  # branch instead links OpenGLES.framework directly and forces the
  # IOS windowing system. That branch hardcodes IPHONE_DEVROOT as
  # /Applications/Xcode.app/... and defaults IPHONE_SDKVER to 10.2, so
  # seed IPHONE_SDKVER with the real SDK version (a -D cache entry wins
  # over OSG's non-FORCE cache default) and make sure the legacy
  # /Applications/Xcode.app path resolves to the active Xcode.
  SDK_VER="$(basename "$SDK" | sed -e 's/^iPhoneOS//' -e 's/\.sdk$//')"
  XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
  if [ ! -e /Applications/Xcode.app ] && [ -d "$XCODE_APP" ]; then
    sudo -n ln -s "$XCODE_APP" /Applications/Xcode.app 2>/dev/null || ln -s "$XCODE_APP" /Applications/Xcode.app 2>/dev/null || true
    echo "- Xcode.app legacy path for OSG iPhone branch: $(ls -ld /Applications/Xcode.app 2>/dev/null || echo unavailable)" >> results/summary.md
  fi
  echo "- OSG iPhone branch: SDKVER=${SDK_VER}" >> results/summary.md
  # Round 13 fix: Run 12 cleared OpenGL, then engine configure failed
  # at the GENERATE step: $<TARGET_FILE:osgdb_dae> (apps/openmw,
  # esmtool, niftest) and Target "osgdb_png" not found. Verified
  # against the pinned OSG fork (OpenMW/osg 01cc2b58) sources:
  # src/osgPlugins/CMakeLists.txt only adds a plugin directory when
  # its package was found - png needs PNG_FOUND AND ZLIB_FOUND, jpeg
  # needs JPEG_FOUND, dae needs COLLADA_FOUND. But the fork's root
  # CMakeLists on APPLE never calls FIND_PACKAGE(PNG) or
  # FIND_PACKAGE(JPEG) at all (legacy "OS X uses QuickTime" branch -
  # it searches TIFF/QuickTime/QTKit instead), so on iOS those two
  # plugins silently never get targets even though deps built
  # libpng.a and libjpeg.a into the sysroot for exactly them.
  # Freetype and ZLIB ARE searched in the fork's common block and are
  # found from the seeded vars / SDK, so only PNG and JPEG need their
  # FOUND flags seeded truthfully (the -D PNG/JPEG include+library
  # vars below already point at the real sysroot libs, and the
  # plugins consume exactly those vars). Collada is different: no
  # collada-dom exists for iOS (it would also need libxml2, pcre and
  # Boost filesystem/system, none of which are in the sysroot), and
  # Morrowind content is NIF-based - osgdb_dae only loads .dae
  # interchange models. Drop osgdb_dae from the cloned tree's
  # USED_OSG_PLUGINS so the components static-plugin list only names
  # targets that can exist; the list is the single source for both
  # the extern OSGDB_* mapping and the components genex list.
  if grep -q "^    osgdb_dae$" build/openmw/CMakeLists.txt; then
    sed -i '' "/^    osgdb_dae$/d" build/openmw/CMakeLists.txt
    echo "- Round 13: removed osgdb_dae from USED_OSG_PLUGINS (no Collada on iOS)" >> results/summary.md
  else
    echo "- Round 13: WARNING osgdb_dae line not found in cloned CMakeLists.txt" >> results/summary.md
  fi
  # Round 14 fix: Run 13 cleared every dep and Configuring finished, then
  # the GENERATE step failed: COCOA_FRAMEWORK is NOTFOUND, linked by
  # target "openmw" (apps/openmw/CMakeLists.txt). That APPLE block does
  # find_library(COCOA_FRAMEWORK Cocoa) - Cocoa is the macOS umbrella
  # framework and does not exist in the iPhone SDK (IOKit in the same
  # block WAS found, so only Cocoa failed). Nothing in apps/openmw or
  # components uses Cocoa APIs (grep is empty); SDL owns the iOS window.
  # The iOS umbrella equivalent is UIKit, so point that find_library at
  # UIKit in the cloned tree. Same block, same problem: its FFmpeg
  # target_link_options list ends with -framework
  # VideoDecodeAcceleration, a macOS-only legacy framework absent on
  # iOS, which would fail the link next even after the generate fix.
  # The sysroot FFmpeg was built with videotoolbox/audiotoolbox
  # disabled, so no decoder acceleration framework is actually needed;
  # swap that token for CoreFoundation (exists on iOS, keeps the
  # command's closing syntax intact). The other four frameworks in the
  # list (CoreVideo, CoreMedia, VideoToolbox, AudioToolbox) all exist
  # in the iPhone SDK.
  APP_CML="build/openmw/apps/openmw/CMakeLists.txt"
  if grep -q "find_library(COCOA_FRAMEWORK Cocoa)" "$APP_CML" && grep -q "VideoDecodeAcceleration" "$APP_CML"; then
    sed -i '' "s/find_library(COCOA_FRAMEWORK Cocoa)/find_library(COCOA_FRAMEWORK UIKit)/" "$APP_CML"
    sed -i '' "s/VideoDecodeAcceleration/CoreFoundation/" "$APP_CML"
    echo "- Round 14: patched apps/openmw Cocoa->UIKit and VideoDecodeAcceleration->CoreFoundation (macOS-only frameworks absent on iOS)" >> results/summary.md
  else
    echo "- Round 14: WARNING expected Cocoa/VideoDecodeAcceleration lines not found in cloned apps/openmw/CMakeLists.txt" >> results/summary.md
  fi
  # Round 15 fix: Run 14 was the first run to clear every dep AND engine
  # configure, then the engine build died in libc++
  # __format/formatter_floating_point.h: 'to_chars' is unavailable:
  # introduced in iOS 16.3. Verified in the local 0.51 source: 36 files
  # include <format> and use std::format (components/bgsm, components/bsa,
  # ...), and Apple libc++ marks std::format and the floating-point
  # std::to_chars unavailable below iOS 16.3. The whole pipeline pinned
  # the deployment target to 15.0, so every one of those translation
  # units was unbuildable. Raise it to 17.0 in the CMAKE_IOS flags above
  # (which the FetchContent extern builds - OSG, MyGUI, Bullet,
  # yaml-cpp - inherit), in IPHONE_VERSION_MIN here, and everywhere in
  # deps/build-all.sh. 17.0 rather than the bare 16.3 minimum gives
  # margin for other libc++ availability gates; the only target device
  # is Arin's iPhone 17 Pro on current iOS, so nothing is lost.
  echo "- Round 15: raised iOS deployment target 15.0 -> 17.0 (std::format/to_chars requires iOS 16.3+)" >> results/summary.md
  # Round 17 fixes (from the Nov 9 research addendum - local source census
  # merged with the web deep-research report; addendum file:
  # research-addendum-2026-11-09.md in the project workspace):
  # (1) Run 16's first error: three engine TUs include the desktop-only
  # <SDL_opengl_glext.h> unguarded; it assumes a desktop gl.h ran first
  # (GLclampd does not exist in GLES3). Every token those files consume
  # exists in <OpenGLES/ES3/glext.h>, so swap the include. This kills
  # the class in all three files, two of which run 16 never reached.
  for F in components/fx/technique.cpp components/debug/gldebug.cpp apps/openmw/mwrender/postprocessor.cpp; do
    if grep -q "#include <SDL_opengl_glext.h>" "build/openmw/$F"; then
      sed -i '' "s|#include <SDL_opengl_glext.h>|#include <OpenGLES/ES3/glext.h>|" "build/openmw/$F"
      echo "- Round 17: swapped SDL_opengl_glext.h -> OpenGLES/ES3/glext.h in $F" >> results/summary.md
    else
      echo "- Round 17: WARNING SDL_opengl_glext.h include not found in $F" >> results/summary.md
    fi
  done
  # (2) Pre-empt the crash catcher: components/crashcatcher/crashcatcher.cpp
  # calls system()/fork()/execl(), all unavailable on iOS, and the component
  # is included for every non-Android build via elseif(NOT ANDROID).
  # Exclude iOS at that same seam.
  COMP_CML="build/openmw/components/CMakeLists.txt"
  if grep -q "^elseif(NOT ANDROID)$" "$COMP_CML"; then
    sed -i '' 's/^elseif(NOT ANDROID)$/elseif(NOT ANDROID AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")/' "$COMP_CML"
    echo "- Round 17: excluded crashcatcher component on iOS (system/fork/execl unavailable)" >> results/summary.md
  else
    echo "- Round 17: WARNING crashcatcher elseif(NOT ANDROID) line not found" >> results/summary.md
  fi
  # (3) Pre-empt the IOKit link failure (sibling of the round 14 Cocoa fix,
  # same APPLE block in apps/openmw/CMakeLists.txt): IOKit.framework does
  # not exist in the iPhone SDK and find_library does not fail at generate,
  # it poisons the link. No engine source calls IOKit APIs (grep empty;
  # SDL owns device input). Point the find at the private device-side
  # spelling's public neighbour: drop it by reusing the UIKit result.
  if grep -q "find_library(IOKIT_FRAMEWORK IOKit)" "$APP_CML"; then
    sed -i '' "s/find_library(IOKIT_FRAMEWORK IOKit)/set(IOKIT_FRAMEWORK \"\")/" "$APP_CML"
    echo "- Round 17: neutralized IOKit find_library in apps/openmw (no IOKit in iPhone SDK)" >> results/summary.md
  else
    echo "- Round 17: WARNING IOKit find_library line not found in apps/openmw/CMakeLists.txt" >> results/summary.md
  fi
  # NOTE (addendum item 5): keep OPENMW_OSX_DEPLOYMENT OFF permanently -
  # upstream's APPLE packaging (Contents/MacOS bundle layout, macOS plist,
  # signing machinery) must never enter this unsigned sideload build; the
  # hand-rolled IPA step below is the packaging route.
  START=$SECONDS
  if cmake -S build/openmw -B build/openmw-b -G "$GEN" "${CMAKE_IOS[@]}" \
      -DOSG_BUILD_PLATFORM_IPHONE=ON \
      -DIPHONE_SDKVER="$SDK_VER" \
      -DIPHONE_VERSION_MIN=17.0 \
      -DOSG_WINDOWING_SYSTEM=IOS \
      -DCMAKE_FRAMEWORK_PATH="$SYSROOT/frameworks" \
      -DRUN_RESULT_VAR=0 \
      -DCMAKE_INSTALL_PREFIX="$ROOT/install-openmw" \
      -DBUILD_OPENMW=ON -DBUILD_LAUNCHER=OFF -DBUILD_WIZARD=OFF -DBUILD_OPENCS=OFF \
      -DBUILD_MWINIIMPORTER=OFF -DBUILD_ESSIMPORTER=OFF -DBUILD_NAVMESHTOOL=OFF \
      -DBUILD_BSATOOL=OFF -DBUILD_BULLETOBJECTTOOL=OFF \
      -DUSE_LUAJIT=OFF \
      -DOPENMW_USE_SYSTEM_MYGUI=OFF \
      -DOPENMW_USE_SYSTEM_OSG=OFF \
      -DOPENMW_USE_SYSTEM_BULLET=OFF \
      -DOPENMW_USE_SYSTEM_YAML_CPP=OFF \
      -DOPENMW_USE_SYSTEM_SQLITE3=OFF \
      -DOPENGL_PROFILE=GLES3 \
      -DPNG_FOUND=TRUE \
      -DJPEG_FOUND=TRUE \
      -DOPENGL_INCLUDE_DIR="$SYSROOT/include" \
      -DOPENGL_gl_LIBRARY="$SDK/System/Library/Frameworks/OpenGLES.framework" \
      -DOPENGL_glu_LIBRARY="$SDK/System/Library/Frameworks/OpenGLES.framework" \
      -DOPENGL_opengl_LIBRARY="$SDK/System/Library/Frameworks/OpenGLES.framework" \
      -DLZ4_INCLUDE_DIR="$SYSROOT/include" \
      -DLZ4_LIBRARY="$SYSROOT/lib/liblz4.a" \
      -DICU_INCLUDE_DIR="$SYSROOT/include" \
      -DICU_UC_LIBRARY="$SYSROOT/lib/libicuuc.a" \
      -DICU_I18N_LIBRARY="$SYSROOT/lib/libicui18n.a" \
      -DICU_DATA_LIBRARY="$SYSROOT/lib/libicudata.a" \
      -DICU_UC_LIBRARY_RELEASE="$SYSROOT/lib/libicuuc.a" \
      -DICU_I18N_LIBRARY_RELEASE="$SYSROOT/lib/libicui18n.a" \
      -DICU_DATA_LIBRARY_RELEASE="$SYSROOT/lib/libicudata.a" \
      -DBoost_DIR="$SYSROOT/lib/cmake/Boost-1.85.0" \
      -Dboost_headers_DIR="$SYSROOT/lib/cmake/boost_headers-1.85.0" \
      -Dboost_iostreams_DIR="$SYSROOT/lib/cmake/boost_iostreams-1.85.0" \
      -Dboost_program_options_DIR="$SYSROOT/lib/cmake/boost_program_options-1.85.0" \
      -DBoost_USE_STATIC_LIBS=ON \
      -DBoost_USE_STATIC_RUNTIME=ON \
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
      -DSDL2_DIR="$SYSROOT/lib/cmake/SDL2" \
      -DLUA_INCLUDE_DIR="$SYSROOT/include/lua5.1" \
      -DLUA_LIBRARY="$SYSROOT/lib/liblua.a" \
      -DLUA_LIBRARIES="$SYSROOT/lib/liblua.a" \
      -DFREETYPE_INCLUDE_DIR_freetype2="$SYSROOT/include/freetype2" \
      -DFREETYPE_INCLUDE_DIR_ft2build="$SYSROOT/include/freetype2" \
      -DFREETYPE_LIBRARY="$SYSROOT/lib/libfreetype.a" \
      -DFREETYPE_LIBRARY_RELEASE="$SYSROOT/lib/libfreetype.a" \
      -DJPEG_INCLUDE_DIR="$SYSROOT/include" \
      -DJPEG_LIBRARY="$SYSROOT/lib/libjpeg.a" \
      -DPNG_INCLUDE_DIR="$SYSROOT/include/libpng18" \
      -DPNG_LIBRARY="$SYSROOT/lib/libpng.a" \
      -DPNG_LIBRARY_RELEASE="$SYSROOT/lib/libpng.a" \
      -DFFmpeg_AVCODEC_INCLUDE_DIR="$SYSROOT/include" \
      -DFFmpeg_AVCODEC_LIBRARY="$SYSROOT/lib/libavcodec.a" \
      -DFFmpeg_AVFORMAT_INCLUDE_DIR="$SYSROOT/include" \
      -DFFmpeg_AVFORMAT_LIBRARY="$SYSROOT/lib/libavformat.a" \
      -DFFmpeg_AVUTIL_INCLUDE_DIR="$SYSROOT/include" \
      -DFFmpeg_AVUTIL_LIBRARY="$SYSROOT/lib/libavutil.a" \
      -DFFmpeg_SWSCALE_INCLUDE_DIR="$SYSROOT/include" \
      -DFFmpeg_SWSCALE_LIBRARY="$SYSROOT/lib/libswscale.a" \
      -DFFmpeg_SWRESAMPLE_INCLUDE_DIR="$SYSROOT/include" \
      -DFFmpeg_SWRESAMPLE_LIBRARY="$SYSROOT/lib/libswresample.a" \
      -DOPENAL_INCLUDE_DIR="$SYSROOT/include" \
      -DOPENAL_LIBRARY="$OPENAL_LIB" \
      -DBOOST_ROOT="$SYSROOT" -DBoost_NO_BOOST_CMAKE=ON -DBoost_NO_SYSTEM_PATHS=ON \
      -DICU_ROOT="$SYSROOT" \
      > logs/engine-configure.log 2>&1; then
    echo "- engine configure: OK" >> results/summary.md
    if cmake --build build/openmw-b -j"$(sysctl -n hw.ncpu)" > logs/engine-build.log 2>&1; then
      echo "- engine build: OK ($((SECONDS-START))s)" >> results/summary.md
    else
      echo "- engine build: FAIL ($((SECONDS-START))s)" >> results/summary.md
      echo "--- first errors:" >> results/summary.md
      grep -m 40 "error:" logs/engine-build.log >> results/summary.md || tail -40 logs/engine-build.log >> results/summary.md
    fi
  else
    echo "- engine configure: FAIL" >> results/summary.md
    echo "--- configure tail:" >> results/summary.md
    tail -40 logs/engine-configure.log >> results/summary.md
  fi
else
  echo "- engine clone: FAIL (tag openmw-51?)" >> results/summary.md
  tail -10 logs/clone-openmw.log >> results/summary.md
  git ls-remote --tags https://github.com/OpenMW/openmw.git 2>/dev/null | grep -E "5[01]" >> results/summary.md || true
fi

# ================= Package unsigned IPA =================
BIN="$(find build/openmw-b -maxdepth 3 -name openmw -type f 2>/dev/null | head -1)"
if [ -n "$BIN" ]; then
  rm -rf package
  mkdir -p package/Payload/OpenMW.app
  cp "$BIN" package/Payload/OpenMW.app/openmw
  [ -d build/openmw-b/resources ] && cp -R build/openmw-b/resources package/Payload/OpenMW.app/
  cat > package/Payload/OpenMW.app/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>openmw</string>
  <key>CFBundleIdentifier</key><string>org.openmw.openmw-ios</string>
  <key>CFBundleName</key><string>OpenMW</string>
  <key>CFBundleDisplayName</key><string>OpenMW</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.51.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIRequiresFullScreen</key><true/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
  <key>UILaunchStoryboardName</key><string></string>
</dict>
</plist>
PLIST
  ( cd package && zip -qry "$SYSROOT/OpenMW-unsigned.ipa" Payload )
  echo "- IPA packaged: $(du -h "$SYSROOT/OpenMW-unsigned.ipa" | cut -f1) (inside sysroot artifact)" >> results/summary.md
else
  echo "- IPA: not packaged (no engine binary)" >> results/summary.md
fi

find "$SYSROOT" \( -name "*.a" -o -name "*.ipa" -o -name "*.dylib" \) | sort >> results/libs.txt || true
{ echo "--- openal inventory:"; find "$SYSROOT" -iname "*openal*" | sort; echo "--- boost cmake inventory:"; find "$SYSROOT/lib/cmake" -maxdepth 2 -name "*.cmake" 2>/dev/null | sort; echo "--- frameworks:"; find "$SYSROOT" -name "*.framework" | sort; } >> results/libs.txt || true
du -sh "$SYSROOT" >> results/summary.md
echo "run.sh done"
