#!/bin/bash
set -e
. set_devkit_path.sh

unset AR AS CC CXX LD OBJCOPY RANLIB STRIP CPPFLAGS LDFLAGS
git clone --depth 1 https://github.com/termux/termux-elf-cleaner || true
cd termux-elf-cleaner
mkdir build
cd build
export CFLAGS=-D__ANDROID_API__=${API}
cmake ..
make -j4
unset CFLAGS
cd ../..

findexec() { find $1 -type f -name "*" -not -name "*.o" -exec sh -c '
    case "$(head -n 1 "$1")" in
      ?ELF*) exit 0;;
      MZ*) exit 0;;
      #!*/ocamlrun*)exit0;;
    esac
exit 1
' sh {} \; -print
}

findexec jreout | xargs ./termux-elf-cleaner/build/termux-elf-cleaner --api-level 24
findexec jdkout | xargs ./termux-elf-cleaner/build/termux-elf-cleaner --api-level 24

cp -rv jre_override/lib/* jreout/lib/ || true

cd jreout

# Strip in place all .so files thanks to the ndk
find ./ -name '*.so' -execdir $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip {} \;

# 复制 libc++_shared.so 到 JRE lib 目录。jre25 的原生库（libjli.so 等）
# 链接了 libc++_shared.so，运行时 linker 必须能在同一目录找到它。
NDK_SYSROOT="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"
# 尝试多个可能的 NDK 目标目录名（NDK 版本间有差异）
NDK_LIBCXX=""
for try_target in "$TARGET" "arm-linux-androideabi" "aarch64-linux-android" "x86_64-linux-android"; do
  try_path="$NDK_SYSROOT/$try_target/libc++_shared.so"
  if [[ -f "$try_path" ]]; then
    NDK_LIBCXX="$try_path"
    break
  fi
done
if [[ -n "$NDK_LIBCXX" ]]; then
  cp "$NDK_LIBCXX" lib/libc++_shared.so
  echo "    -> copied libc++_shared.so ($NDK_LIBCXX) to lib/"
else
  echo "    WARNING: libc++_shared.so not found in NDK sysroot ($NDK_SYSROOT)"
fi

tar cJf ../jre25-${TARGET_JDK}-`date +%Y%m%d`-${JDK_DEBUG_LEVEL}.tar.xz .