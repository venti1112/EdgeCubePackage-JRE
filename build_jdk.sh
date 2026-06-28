#!/bin/bash
set -e
. set_devkit_path.sh

export FREETYPE_DIR=$PWD/freetype-$BUILD_FREETYPE_VERSION/build_android-$TARGET_SHORT
export CUPS_DIR=$PWD/cups-2.2.4
export CFLAGS+=" -DLE_STANDALONE"

if [[ "$TARGET_JDK" == "arm" ]]
then
  export CFLAGS+=" -O3 -D__thumb__"
else
  if [[ "$TARGET_JDK" == "x86" ]]; then
     export CFLAGS+=" -O3 -mstackrealign"
  else
     export CFLAGS+=" -O3"
  fi
fi

ln -s -f /usr/include/X11 $ANDROID_INCLUDE/
ln -s -f /usr/include/fontconfig $ANDROID_INCLUDE/
platform_args="--with-toolchain-type=gcc \
  --with-freetype-include=$FREETYPE_DIR/include/freetype2 \
  --with-freetype-lib=$FREETYPE_DIR/lib \
  "
AUTOCONF_x11arg="--x-includes=$ANDROID_INCLUDE/X11"

export BOOT_JDK=$PWD/jdk-10.0.2
export CFLAGS+=" -DANDROID"
export LDFLAGS+=" -L$PWD/dummy_libs"

# Create dummy libraries so we won't have to remove them in OpenJDK makefiles
mkdir -p dummy_libs
ar cru dummy_libs/libpthread.a
ar cru dummy_libs/librt.a
ar cru dummy_libs/libthread_db.a

# fix building libjawt
ln -s -f $CUPS_DIR/cups $ANDROID_INCLUDE/

cd openjdk

# Apply patches
git reset --hard
git apply --reject --whitespace=fix ../patches/jdk11u_android.diff || echo "git apply failed (Android patch set)"

# Add iconv extern declarations for Android (tinyiconv provides the implementation
# but Bionic only declares the functions for __ANDROID_API__ >= 28)
# Also fix rejected patch hunks: add EXTRA_SRC for tinyiconv to libjdwp and libinstrument
python3 << 'PYEOF'
import os

# 1. Add iconv extern declarations to source files
src_files = [
    "src/java.instrument/unix/native/libinstrument/EncodingSupport_md.c",
    "src/jdk.jdwp.agent/share/native/libjdwp/utf_util.c",
]
decl = """#ifdef __ANDROID__
extern iconv_t iconv_open(const char*, const char*);
extern size_t iconv(iconv_t, char**, size_t*, char**, size_t*);
extern int iconv_close(iconv_t);
#endif
"""
for f in src_files:
    if os.path.exists(f) and "extern iconv_t iconv_open" not in open(f).read():
        content = open(f).read()
        content = content.replace("#include <iconv.h>\n", "#include <iconv.h>\n" + decl, 1)
        open(f, "w").write(content)
        print("[build_jdk] Added iconv extern declarations to " + f)

# 2. Fix rejected patch hunks: add EXTRA_SRC + CXXFLAGS to build files
#    The patch hunks for Lib-jdk.jdwp.agent.gmk and Lib-java.instrument.gmk
#    may be rejected due to context line mismatches. Each fix uses its own
#    check string so it is only applied once even if EXTRA_SRC is already present.
build_fixes = [
    # (file, anchor_line, line_to_add, check_string)
    # Add EXTRA_SRC + CXXFLAGS to BUILD_LIBJDWP. The anchor "CFLAGS := ... -DJDWP_LOGGING"
    # is unique to BUILD_LIBJDWP. Do NOT use "libjdwp/export" as anchor — it also appears
    # in BUILD_LIBDT_SOCKET, and replace(..., 1) would match the wrong block.
    ("make/lib/Lib-jdk.jdwp.agent.gmk",
     "    CFLAGS := $(CFLAGS_JDKLIB) -DJDWP_LOGGING, \\",
     "    EXTRA_SRC := java.base:libtinyiconv, \\\n    CXXFLAGS := $(CXXFLAGS_JDKLIB), \\",
     "EXTRA_SRC := java.base:libtinyiconv"),
    ("make/lib/Lib-java.instrument.gmk",
     "    EXTRA_HEADER_DIRS := java.base:libjli, \\",
     "    EXTRA_SRC := java.base:libtinyiconv, \\",
     "EXTRA_SRC := java.base:libtinyiconv"),
    ("make/lib/Lib-java.instrument.gmk",
     "    CFLAGS := $(CFLAGS_JDKLIB) $(LIBINSTRUMENT_CFLAGS), \\",
     "    CXXFLAGS := $(CXXFLAGS_JDKLIB), \\",
     "CXXFLAGS := $(CXXFLAGS_JDKLIB)"),
]
for gmk, anchor, line, check in build_fixes:
    if os.path.exists(gmk):
        content = open(gmk).read()
        if check not in content:
            if anchor in content:
                content = content.replace(anchor, anchor + "\n" + line, 1)
                open(gmk, "w").write(content)
                print("[build_jdk] Added to " + gmk + ": " + line.strip())
            else:
                print("[build_jdk] WARNING: anchor not found in " + gmk + ": " + anchor.strip())

# 3. Add CXXFLAGS to BUILD_LIBDT_SOCKET (tinyiconv's iconv.cpp is compiled
#    as part of libdt_socket and needs C++ flags to avoid -std=c99 error).
#    This must be checked separately because CXXFLAGS already exists in
#    BUILD_LIBJDWP, so the file-wide check above would skip it.
gmk = 'make/lib/Lib-jdk.jdwp.agent.gmk'
if os.path.exists(gmk):
    content = open(gmk).read()
    dt_start = content.find('BUILD_LIBDT_SOCKET')
    dt_end = content.find('))', dt_start)
    if dt_start != -1 and dt_end != -1:
        dt_block = content[dt_start:dt_end]
        if 'CXXFLAGS' not in dt_block:
            anchor = '$(LIBDT_SOCKET_CPPFLAGS), \\'
            if anchor in dt_block:
                content = content.replace(anchor, anchor + '\n    CXXFLAGS := $(CXXFLAGS_JDKLIB), \\', 1)
                open(gmk, 'w').write(content)
                print('[build_jdk] Added CXXFLAGS to BUILD_LIBDT_SOCKET in ' + gmk)
            else:
                print('[build_jdk] WARNING: BUILD_LIBDT_SOCKET anchor not found in ' + gmk)
        else:
            print('[build_jdk] BUILD_LIBDT_SOCKET already has CXXFLAGS in ' + gmk)

# 4. Guard coalesce_subword_stores disable with __ANDROID__ so the build JDK
#    (compiled for linux-amd64 host) keeps the original code. The Android patch
#    unconditionally comments out this C2 optimization, but it affects the build
#    JDK too, causing incorrect object initialization → SIGSEGV in
#    ObjectSynchronizer::inflate during jmod creation.
memnode = 'src/hotspot/share/opto/memnode.cpp'
if os.path.exists(memnode):
    content = open(memnode).read()
    old = '  // if (ReduceFieldZeroing || ReduceBulkZeroing)\n    // reduce instruction count for common initialization patterns\n    // coalesce_subword_stores(header_size, size_in_bytes, phase);'
    new = '#ifndef __ANDROID__\n  if (ReduceFieldZeroing || ReduceBulkZeroing)\n    // reduce instruction count for common initialization patterns\n    coalesce_subword_stores(header_size, size_in_bytes, phase);\n#endif'
    if old in content:
        content = content.replace(old, new, 1)
        open(memnode, 'w').write(content)
        print('[build_jdk] Guarded coalesce_subword_stores disable with __ANDROID__ in ' + memnode)
    elif '#ifndef __ANDROID__\n  if (ReduceFieldZeroing || ReduceBulkZeroing)' in content:
        print('[build_jdk] coalesce_subword_stores already guarded in ' + memnode)
    else:
        print('[build_jdk] WARNING: coalesce_subword_stores pattern not found in ' + memnode)

# 5. Revert toolchain.m4 BUILD_CC changes: the Android patch changes BUILD_CC
#    lookup from "cc gcc" to "clang cc gcc", causing the BUILD JDK to be
#    compiled with clang. Clang doesn't support -fno-lifetime-dse, which is
#    critical for correct HotSpot operation (prevents the compiler from
#    optimizing away stores to object headers during construction).
#    Without it, the BUILD JDK crashes with SIGSEGV in
#    ObjectSynchronizer::inflate during jmod creation.
#    The patch also skips BUILD compiler version extraction on linux, which
#    can cause missing version-specific workarounds.
toolchain_m4 = 'make/autoconf/toolchain.m4'
if os.path.exists(toolchain_m4):
    content = open(toolchain_m4).read()
    changed = False

    # Revert BUILD_CC/BUILD_CXX lookup to prefer gcc (original behavior)
    # Use replace_all=True because the patch creates two identical lines
    # (macOS branch + else branch); the else branch is the one we need to fix.
    old_cc = 'UTIL_REQUIRE_PROGS(BUILD_CC, clang cc gcc)'
    new_cc = 'UTIL_REQUIRE_PROGS(BUILD_CC, cc gcc)'
    if old_cc in content:
        content = content.replace(old_cc, new_cc)
        changed = True
        print('[build_jdk] Reverted BUILD_CC lookup to "cc gcc" in ' + toolchain_m4)

    old_cxx = 'UTIL_REQUIRE_PROGS(BUILD_CXX, clang++ CC g++)'
    new_cxx = 'UTIL_REQUIRE_PROGS(BUILD_CXX, CC g++)'
    if old_cxx in content:
        content = content.replace(old_cxx, new_cxx)
        changed = True
        print('[build_jdk] Reverted BUILD_CXX lookup to "CC g++" in ' + toolchain_m4)

    # Restore BUILD compiler version extraction (patch skips it on linux)
    old_ver = """    # xandroid
    if test "x$OPENJDK_BUILD_OS" != "xlinux"; then
      TOOLCHAIN_EXTRACT_COMPILER_VERSION(BUILD_CC, [BuildC])
      TOOLCHAIN_EXTRACT_COMPILER_VERSION(BUILD_CXX, [BuildC++])
      TOOLCHAIN_PREPARE_FOR_VERSION_COMPARISONS([BUILD_], [OPENJDK_BUILD_], [build ])
      TOOLCHAIN_EXTRACT_LD_VERSION(BUILD_LD, [build linker])
      TOOLCHAIN_PREPARE_FOR_LD_VERSION_COMPARISONS([BUILD_], [OPENJDK_BUILD_])
    fi"""
    new_ver = """    TOOLCHAIN_EXTRACT_COMPILER_VERSION(BUILD_CC, [BuildC])
    TOOLCHAIN_EXTRACT_COMPILER_VERSION(BUILD_CXX, [BuildC++])
    TOOLCHAIN_PREPARE_FOR_VERSION_COMPARISONS([BUILD_], [OPENJDK_BUILD_])
    TOOLCHAIN_EXTRACT_LD_VERSION(BUILD_LD, [build linker])
    TOOLCHAIN_PREPARE_FOR_LD_VERSION_COMPARISONS([BUILD_], [OPENJDK_BUILD_])"""
    if old_ver in content:
        content = content.replace(old_ver, new_ver, 1)
        changed = True
        print('[build_jdk] Restored BUILD compiler version extraction in ' + toolchain_m4)

    if changed:
        open(toolchain_m4, 'w').write(content)
    else:
        print('[build_jdk] toolchain.m4 BUILD_CC changes already reverted or not found')
PYEOF

bash ./configure \
    --with-boot-jdk=$BOOT_JDK \
    --openjdk-target=$TARGET \
    --with-extra-cflags="$CFLAGS" \
    --with-extra-cxxflags="$CFLAGS" \
    --with-extra-ldflags="$LDFLAGS" \
    --disable-precompiled-headers \
    --disable-warnings-as-errors \
    --enable-option-checking=fatal \
    --enable-headless-only=yes \
    --with-jvm-variants=$JVM_VARIANTS \
    --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc \
    --with-cups-include=$CUPS_DIR \
    --with-devkit=$TOOLCHAIN \
    --with-native-debug-symbols=external \
    --with-debug-level=$JDK_DEBUG_LEVEL \
    --with-fontconfig-include=$ANDROID_INCLUDE \
    --with-version-pre= \
    --with-version-opt= \
    $AUTOCONF_x11arg $AUTOCONF_EXTRA_ARGS \
    --x-libraries=/usr/lib \
        $platform_args || \
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "\n\nCONFIGURE ERROR $error_code , config.log:"
  cat config.log
  exit $error_code
fi

jobs=4

cd build/${JVM_PLATFORM}-${TARGET_JDK}-normal-${JVM_VARIANTS}-${JDK_DEBUG_LEVEL}

# Clear VERSION_PRE and VERSION_OPT in spec.gmk as a backup in case the
# --with-version-pre=/--with-version-opt= configure options were not applied.
# VERSION_STRING is pre-computed during configure, so also fix it directly.
sed -i 's/^VERSION_PRE[ ]*[:?+]*=.*/VERSION_PRE :=/' spec.gmk
sed -i 's/^VERSION_OPT[ ]*[:?+]*=.*/VERSION_OPT :=/' spec.gmk
sed -i 's/^VERSION_STRING[ ]*[:?+]*=.*/VERSION_STRING := $(VERSION_NUMBER)/' spec.gmk
echo "[build_jdk] Cleared VERSION_PRE/VERSION_OPT/VERSION_STRING in $(pwd)/spec.gmk"

# Safety measure: disable C2 for the BUILD JDK. The primary fix is using gcc
# for BUILD_CC (see toolchain.m4 reversion above) which enables -fno-lifetime-dse.
# This C2 disable is kept as an extra safety net.
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -XX:TieredStopAtLevel=1"
echo "[build_jdk] Set JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS"

make JOBS=$jobs images || \
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "Build failure, exited with code $error_code. Trying again."
  make JOBS=$jobs images
fi
