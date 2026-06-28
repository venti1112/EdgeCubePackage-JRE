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
  --build=x86_64-unknown-linux-gnu \
  "
AUTOCONF_x11arg="--x-includes=$ANDROID_INCLUDE/X11"
AUTOCONF_EXTRA_ARGS+="OBJCOPY=$OBJCOPY \
  AR=$AR \
  STRIP=$STRIP \
  "

export BOOT_JDK=$PWD/jdk-20
export CFLAGS+=" -DANDROID"
export LDFLAGS+=" -L$PWD/dummy_libs"

# Detect LLD 17+ and add --undefined-version to suppress strict version-script errors.
# LLD 17+ (NDK 25+) changed the default to error on undefined version-script symbols
# (e.g. OpenJDK's libjvm.so mapfile references vtable symbols for function-local closure
# classes that the compiler does not emit). LLD < 17 (e.g. NDK r21's LLD 9) treats these
# as warnings by default. The --undefined-version flag restores the old permissive
# behavior on LLD 17+. We gate on the detected major version so the flag is only added
# when needed. See FreeBSD Bug 274106 for the same issue.
if [[ -x "$TOOLCHAIN/bin/ld.lld" ]]; then
  LLD_MAJOR=$("$TOOLCHAIN/bin/ld.lld" --version 2>&1 | head -n1 | sed -n 's/^LLD \([0-9][0-9]*\)\..*/\1/p')
  if [[ -n "$LLD_MAJOR" && "$LLD_MAJOR" -ge 17 ]]; then
    export LDFLAGS+=" -Wl,--undefined-version"
    echo "[build_jdk] LLD $LLD_MAJOR detected; appending -Wl,--undefined-version to LDFLAGS"
  else
    echo "[build_jdk] LLD ${LLD_MAJOR:-unknown} detected; not adding --undefined-version"
  fi
fi

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
git apply --reject --whitespace=fix ../patches/jdk21u_android.diff || echo "git apply failed (Android patch set)"

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

cd build/${JVM_PLATFORM}-${TARGET_JDK}-${JVM_VARIANTS}-${JDK_DEBUG_LEVEL}
make JOBS=$jobs images || \
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "Build failure, exited with code $error_code. Trying again."
  make JOBS=$jobs images
fi
