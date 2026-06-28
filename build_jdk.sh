#!/bin/bash
set -e
. set_devkit_path.sh

if [[ "$TARGET_JDK" == "arm" ]]
then
  export TARGET_JDK=aarch32
  export TARGET_PHYS=aarch32-linux-androideabi
  export JVM_VARIANTS=client
else
  export TARGET_PHYS=$TARGET
fi

export FREETYPE_DIR=$PWD/freetype-$BUILD_FREETYPE_VERSION/build_android-$TARGET_SHORT
export CUPS_DIR=$PWD/cups-2.2.4
export CFLAGS+=" -DLE_STANDALONE"

export CFLAGS+=" -O3 -D__ANDROID__"

ln -s -f /usr/include/X11 $ANDROID_INCLUDE/
ln -s -f /usr/include/fontconfig $ANDROID_INCLUDE/
AUTOCONF_x11arg="--x-includes=$ANDROID_INCLUDE/X11"

export LDFLAGS+=" -L`pwd`/dummy_libs"

# Create dummy libraries so we won't have to remove them in OpenJDK makefiles
mkdir -p dummy_libs
ar cru dummy_libs/libpthread.a
ar cru dummy_libs/libthread_db.a

# fix building libjawt
ln -s -f $CUPS_DIR/cups $ANDROID_INCLUDE/

cd openjdk

# Apply patches
git reset --hard
git apply --reject --whitespace=fix ../patches/jdk8u_android.diff || echo "git apply failed (universal patch set)"
if [[ "$TARGET_JDK" != "aarch32" ]]; then
  git apply --reject --whitespace=fix ../patches/jdk8u_android_main.diff || echo "git apply failed (main non-universal patch set)"
else
  git apply --reject --whitespace=fix ../patches/jdk8u_android_aarch32.diff || echo "git apply failed (aarch32 non-universal patch set)"
fi
if [[ "$TARGET_JDK" == "x86" ]]; then
  git apply --reject --whitespace=fix ../patches/jdk8u_android_page_trap_fix.diff || echo "git apply failed (x86 page trap fix)"
fi

# Disable GCC < 5 check on aarch64 (NDK r10e uses GCC 4.9, JDK-8360869)
# sed alone is unreliable: the as_fn_error call may be in common/autoconf/generated-configure.sh
# (the actual autoconf-generated script that `configure` sources) rather than in `configure`
# itself, and the call may span multiple lines. Use Python to find and neutralize any line
# containing the GCC < 5 error message in both files.
python3 << 'PYEOF'
import os

for cfg_file in ['configure', 'common/autoconf/generated-configure.sh']:
    if not os.path.exists(cfg_file):
        continue
    with open(cfg_file, 'r', errors='ignore') as f:
        content = f.read()
    if 'GCC < 5 may incorrectly' not in content:
        continue
    lines = content.split('\n')
    new_lines = []
    modified = 0
    for line in lines:
        if 'GCC < 5 may incorrectly' in line:
            indent = line[:len(line) - len(line.lstrip())]
            new_lines.append(indent + ': # GCC < 5 check disabled (NDK r10e GCC 4.9, JDK-8360869)')
            modified += 1
        else:
            new_lines.append(line)
    with open(cfg_file, 'w') as f:
        f.write('\n'.join(new_lines))
    print("[build_jdk] Disabled GCC < 5 check in " + cfg_file + " (" + str(modified) + " line(s))")
PYEOF

bash ./configure \
    --openjdk-target=$TARGET_PHYS \
    --with-extra-cflags="$CFLAGS" \
    --with-extra-cxxflags="$CFLAGS" \
    --with-extra-ldflags="$LDFLAGS" \
    --enable-option-checking=fatal \
    --with-jdk-variant=normal \
    --with-jvm-variants="${JVM_VARIANTS/AND/,}" \
    --with-cups-include=$CUPS_DIR \
    --with-devkit=$TOOLCHAIN \
    --with-debug-level=$JDK_DEBUG_LEVEL \
    --with-fontconfig-include=$ANDROID_INCLUDE \
    --with-freetype-lib=$FREETYPE_DIR/lib \
    --with-freetype-include=$FREETYPE_DIR/include/freetype2 \
    --with-milestone=fcs \
    $AUTOCONF_x11arg $AUTOCONF_EXTRA_ARGS \
    --x-libraries=/usr/lib \
        $platform_args || \
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "\n\nCONFIGURE ERROR $error_code , config.log:"
  cat config.log
  exit $error_code
fi

cd build/${JVM_PLATFORM}-${TARGET_JDK}-normal-${JVM_VARIANTS}-${JDK_DEBUG_LEVEL}

# Set MILESTONE=fcs in spec.gmk as a backup in case --with-milestone=fcs was
# not applied. JDK 8 uses MILESTONE (not VERSION_PRE/VERSION_OPT). The "fcs"
# value is special-cased in spec.gmk.in to drop the milestone from RELEASE.
sed -i 's/^MILESTONE[ ]*[:?+]*=.*/MILESTONE := fcs/' spec.gmk
echo "[build_jdk] Set MILESTONE=fcs in $(pwd)/spec.gmk"

make JOBS=4 images || \
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "Build failure, exited with code $error_code. Trying again."
  make JOBS=4 images
fi
