#!/bin/bash
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
CMAKE_IOS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$SYSROOT" -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

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
  START=$SECONDS
  if cmake -S build/openmw -B build/openmw-b -G "$GEN" "${CMAKE_IOS[@]}" \
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
      -DOPENGL_INCLUDE_DIR="$SDK/System/Library/Frameworks/OpenGLES.framework/Headers" \
      -DOPENGL_gl_LIBRARY="$SDK/System/Library/Frameworks/OpenGLES.framework" \
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
