# OpenMW on iPhone — FULL build port plan (Arin's call, Nov 8, 2026)

Goal: Arin's full Mac build (318 content files, ~37 GB) running natively on their iPhone 17 Pro. Not streaming, not a lite build.

## Proven possible
- TechSpot (Sep 2026): a non-coder AI-ported OpenMW to iOS; Morrowind runs 60 FPS with touch controls on an iPhone weaker than the 17 Pro. His port was never publicly released (GitHub checked Nov 8, 2026: only eDukeiOS + SeriousiOS are public) — we build our own from the same source he used.
- No official OpenMW iOS build exists (official downloads: Windows/macOS/Linux only).

## Inputs ready
- OpenMW 0.51.0 source cloned at ~/workspace/openmw-ios/src (VM copy for study; the real build tree goes on the Mac).
- Mac build to mirror: openmw.cfg (data=215, content=318), game data 1.0 GB + modlist 36 GB on the Mac.
- SideStore route already familiar from the iOS emulation thread; no JIT needed (native app, Lua is interpreted). Free Apple ID = 7-day re-sign, SideStore auto-refreshes.

## GATE (blocks everything below)
1. Mac disk: 16.9 GB free — need ~30+ GB for Xcode + build tree. Arin must evict iCloud "Project Files" in Finder (Remove Download, ~32 GB). Nothing Nova-owned on the Mac is big enough to substitute.
2. Xcode not installed (only Command Line Tools). Install after the eviction (browser/App Store route, ~15 GB). Also need cmake + ninja (brew or standalone under ~/workspace/tools rules — on the Mac, ~/openmw-rebuild/ is the staging home).

## Dependency map (from 0.51.0 CMakeLists, read Nov 8, 2026)
Engine-only build: BUILD_OPENMW=ON; LAUNCHER/WIZARD/OPENCS/MWINIIMPORTER/NAVMESHTOOL/tools OFF (kills the Qt6 requirement).
Cross-compile for iOS arm64, in rough order:
- SDL2 2.0.20+ (official iOS support — easy)
- LZ4 (trivial), SQLite3 (in iOS SDK), yaml-cpp (internal allowed), RecastNavigation (bundled)
- Bullet (portable C++ — easy)
- FFmpeg avcodec/avformat/avutil/swscale/swresample (routine iOS build)
- MyGUI (portable; needs freetype — freetype builds for iOS fine)
- OpenAL: Apple ships OpenAL.framework (deprecated, present) or build openal-soft for iOS
- ICU (uc/i18n/data) — heaviest of the small deps; system ICU option or cross-build
- Boost iostreams only (program_options is launcher-side)
- Lua: USE_LUAJIT=OFF → plain Lua + bundled sol3 (extern/). LuaJIT on iOS runs interpreter-only anyway; plain Lua is the safe route, script mods still work, slightly slower.
- OSG 3.6.5 (OpenMW fork) — the main event: build with OPENGL_PROFILE=GLES3 (iOS ships OpenGL ES, deprecated but present; this is the route the public proof used).

## Known risks
- GLES rendering quirks on iOS (the Mac build already needed the per-pixel-lighting workaround for Apple Silicon).
- Some 0.51 Lua script mods may hit iOS sandbox/path issues (config + data live in the app's container; paths in openmw.cfg must be container-relative).
- Memory: iOS per-app limit on 17 Pro (~6 GB with the increased-memory entitlement — the same entitlement the emulators use; sideloaded apps can request it via entitlements file at signing).

## Sequence
1. Eviction → Xcode + cmake/ninja on the Mac.
2. Cross-compile deps (script each, log versions — mirror CI/macos/deps_versions.sh pins where sensible).
3. Configure engine-only iOS build; fix compile errors iteratively.
4. Package .ipa, sideload via SideStore, smoke-test VANILLA (game data only, 1 GB).
5. Transfer the full 37 GB stack into the app container (wired/Finder file sharing or SideStore container access), port openmw.cfg, validate content list.
6. Enable script mods in groups; fix pathing issues; PS5 controller pairing test.
7. Write up in REBUILD_SPEC.md + MEMORY.md.
