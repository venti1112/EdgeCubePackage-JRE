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
#    may be rejected due to context line mismatches.
build_fixes = [
    ("make/lib/Lib-jdk.jdwp.agent.gmk",
     "      libjdwp/export, \\",
     "    EXTRA_SRC := java.base:libtinyiconv, \\"),
    ("make/lib/Lib-java.instrument.gmk",
     "    EXTRA_HEADER_DIRS := java.base:libjli, \\",
     "    EXTRA_SRC := java.base:libtinyiconv, \\"),
]
for gmk, anchor, line in build_fixes:
    if os.path.exists(gmk) and "libtinyiconv" not in open(gmk).read():
        content = open(gmk).read()
        if anchor in content:
            content = content.replace(anchor, anchor + "\n" + line, 1)
            open(gmk, "w").write(content)
            print("[build_jdk] Added EXTRA_SRC to " + gmk)
        else:
            print("[build_jdk] WARNING: anchor not found in " + gmk)
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
    --with-version-opt= \
    --with-fontconfig-include=$ANDROID_INCLUDE \
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
make JOBS=$jobs images || \
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "Build failure, exited with code $error_code. Trying again."
  make JOBS=$jobs images
fi
