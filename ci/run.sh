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
CMAKE_IOS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$SYSROOT")

if git clone --depth 1 --branch openmw-51 https://github.com/OpenMW/openmw.git build/openmw > logs/clone-openmw.log 2>&1; then
  GEN="Unix Makefiles"; command -v ninja >/dev/null && GEN="Ninja"
  echo "- generator: $GEN" >> results/summary.md
  START=$SECONDS
  if cmake -S build/openmw -B build/openmw-b -G "$GEN" "${CMAKE_IOS[@]}" \
      -DCMAKE_INSTALL_PREFIX="$ROOT/install-openmw" \
      -DBUILD_OPENMW=ON -DBUILD_LAUNCHER=OFF -DBUILD_WIZARD=OFF -DBUILD_OPENCS=OFF \
      -DBUILD_MWINIIMPORTER=OFF -DBUILD_ESSIMPORTER=OFF -DBUILD_NAVMESHTOOL=OFF \
      -DBUILD_BSATOOL=OFF -DBUILD_BULLETOBJECTTOOL=OFF \
      -DUSE_LUAJIT=OFF \
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

find "$SYSROOT" \( -name "*.a" -o -name "*.ipa" \) | sort >> results/libs.txt || true
du -sh "$SYSROOT" >> results/summary.md
echo "run.sh done"
