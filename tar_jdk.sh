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

tar cJf ../jre25-${TARGET_JDK}-`date +%Y%m%d`-${JDK_DEBUG_LEVEL}.tar.xz .