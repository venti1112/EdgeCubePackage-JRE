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

# Fix JRE8 aarch64 runtime crash on Android: "Field too big for insn"
# Root cause: Android ASLR places CodeCache ~156MB from libjvm.so, exceeding
# the ±128MB range of the AArch64 B (unconditional branch) instruction.
# JDK 8 lacks far-branch trampolines (added in JDK 11+ via MacroAssembler::far_branch).
# Fix: When no specific address is requested, try to mmap near libjvm.so
# so branch instructions from CodeCache can reach libjvm.so functions.
# Only applies to aarch64 (the crash is aarch64-specific; other archs are unaffected).
if [[ "$TARGET_JDK" == "aarch64" ]]; then
python3 << 'PYEOF'
import os

filepath = 'hotspot/src/os/linux/vm/os_linux.cpp'
if not os.path.exists(filepath):
    print('[build_jdk] WARNING: ' + filepath + ' not found')
else:
    with open(filepath, 'r') as f:
        content = f.read()

    if 'get_libjvm_base' in content:
        print('[build_jdk] CodeCache near-jvm fix already applied in ' + filepath)
    else:
        # 1. Add get_libjvm_base() helper before anon_mmap.
        #    Uses dladdr on itself to find libjvm.so's base address.
        #    __attribute__((noinline)) ensures the function has a distinct address.
        helper = """
// [EdgeCube] Get libjvm.so base address for CodeCache placement on Android aarch64.
// JDK 8 lacks far-branch trampolines; CodeCache must be within +/-128MB of
// libjvm.so for the B (unconditional branch) instruction to work.
__attribute__((noinline)) static void* get_libjvm_base() {
  Dl_info info;
  if (dladdr((void*)&get_libjvm_base, &info) && info.dli_fbase) {
    return info.dli_fbase;
  }
  return NULL;
}

"""
        anchor1 = 'static char* anon_mmap(char* requested_addr, size_t bytes, bool fixed) {'
        if anchor1 in content:
            content = content.replace(anchor1, helper + anchor1, 1)
        else:
            print('[build_jdk] WARNING: anon_mmap anchor not found in ' + filepath)

        # 2. Add hint logic inside anon_mmap, before the mmap call.
        #    When !fixed && requested_addr == NULL, try mmap near libjvm.so.
        anchor2 = """  // Map reserved/uncommitted pages PROT_NONE so we fail early if we
  // touch an uncommitted page. Otherwise, the read/write might
  // succeed if we have enough swap space to back the physical page.
  addr = (char*)::mmap(requested_addr, bytes, PROT_NONE,
                       flags, -1, 0);"""

        hint_code = """#ifdef __ANDROID__
  // [EdgeCube] Android aarch64: try to allocate near libjvm.so when no
  // specific address is requested. This keeps CodeCache within branch range.
  if (!fixed && requested_addr == NULL) {
    void* jvm_base_ptr = get_libjvm_base();
    if (jvm_base_ptr != NULL) {
      uintptr_t jvm_base = (uintptr_t)jvm_base_ptr;
      // Try 32MB below libjvm.so (well within +/-128MB B instruction range)
      uintptr_t hint = (jvm_base > 32 * 1024 * 1024)
          ? (jvm_base - 32 * 1024 * 1024) : jvm_base;
      hint &= ~((uintptr_t)os::Linux::page_size() - 1); // page-align
      addr = (char*)::mmap((char*)hint, bytes, PROT_NONE, flags, -1, 0);
      if (addr != MAP_FAILED) {
        uintptr_t distance = (uintptr_t)addr > jvm_base
            ? (uintptr_t)addr - jvm_base
            : jvm_base - (uintptr_t)addr;
        if (distance < 120 * 1024 * 1024) {
          if ((address)addr + bytes > _highest_vm_reserved_address) {
            _highest_vm_reserved_address = (address)addr + bytes;
          }
          return addr;
        }
        // Too far from libjvm.so, unmap and fall through to default
        ::munmap(addr, bytes);
      }
    }
  }
#endif

  // Map reserved/uncommitted pages PROT_NONE so we fail early if we
  // touch an uncommitted page. Otherwise, the read/write might
  // succeed if we have enough swap space to back the physical page.
  addr = (char*)::mmap(requested_addr, bytes, PROT_NONE,
                       flags, -1, 0);"""

        if anchor2 in content:
            content = content.replace(anchor2, hint_code, 1)
            with open(filepath, 'w') as f:
                f.write(content)
            print('[build_jdk] Applied CodeCache near-jvm fix to ' + filepath)
        else:
            with open(filepath, 'w') as f:
                f.write(content)
            print('[build_jdk] WARNING: mmap anchor not found, wrote helper only to ' + filepath)
PYEOF
fi

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
