#!/usr/bin/env bash
# Builds Buddy's native libraries for arm64 Android, all from source, into app/src/main/jniLibs/arm64-v8a:
#   libproot.so + libproot-loader.so  PRoot (Termux's fork), runs the built-in Linux
#   libtalloc.so                      talloc, PRoot's memory allocator
#   libandroid-shmem.so               System V shared memory for PRoot's guests
#   libbuddypty.so                    the terminal's pty helper (pty.c)
# With ANDROID_NDK_HOME set it uses that NDK (CI); otherwise Termux's clang on the phone
# (pkg install clang make readelf). Sources: third_party/proot and third_party/libandroid-shmem (git submodules:
# git submodule update --init) and talloc's three files in third_party/talloc. They're copied into build/ first, so
# the build never changes them, and paths are mapped so the libraries come out the same wherever they're built
# (F-Droid's reproducible build compares its APK with the one on GitHub).
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
API=30
PROOT_VERSION=5.1.107.102 # third_party/proot is at this tag
TP=$HERE/../third_party

OUT=$HERE/../app/src/main/jniLibs/arm64-v8a
WORK=$HERE/build
mkdir -p "$OUT" "$WORK/src" "$WORK/lib" "$WORK/include/sys"

# One-token CC wrapper: make splits on spaces, and Windows NDK paths / Git Bash break a multi-word CC= line.
CC_WRAP=$WORK/buddy-cc
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  BIN=$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin)
  # Prefer a real host prebuilt (linux on CI/WSL, windows on Git Bash); take the first clang that exists.
  CLANG=""
  for d in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin; do
    if [[ -x "$d/clang" || -x "$d/clang.exe" ]]; then BIN=$d; break; fi
  done
  if [[ -x "$BIN/clang" ]]; then CLANG=$BIN/clang
  elif [[ -x "$BIN/clang.exe" ]]; then CLANG=$BIN/clang.exe
  else
    echo "No clang in NDK at $ANDROID_NDK_HOME (looked under toolchains/llvm/prebuilt/*/bin)" >&2
    exit 1
  fi
  STRIP=$BIN/llvm-strip; OBJCOPY=$BIN/llvm-objcopy; OBJDUMP=$BIN/llvm-objdump
  [[ -x "$BIN/llvm-strip.exe" && ! -x "$STRIP" ]] && STRIP=$BIN/llvm-strip.exe
  [[ -x "$BIN/llvm-objcopy.exe" && ! -x "$OBJCOPY" ]] && OBJCOPY=$BIN/llvm-objcopy.exe
  [[ -x "$BIN/llvm-objdump.exe" && ! -x "$OBJDUMP" ]] && OBJDUMP=$BIN/llvm-objdump.exe
  cat > "$CC_WRAP" <<EOF
#!/usr/bin/env bash
exec "$CLANG" --target=aarch64-linux-android$API -ffile-prefix-map=$WORK=. -ffile-prefix-map=$HERE=native "\$@"
EOF
else
  STRIP=llvm-strip OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
  cat > "$CC_WRAP" <<EOF
#!/usr/bin/env bash
exec clang --target=aarch64-linux-android$API -ffile-prefix-map=$WORK=. -ffile-prefix-map=$HERE=native "\$@"
EOF
fi
chmod +x "$CC_WRAP"
CC=$CC_WRAP
LDPAGE=-Wl,-z,max-page-size=16384

# Termux's clang always adds its own library path; the app's libraries must not carry it.
finish() { # built file, name in the APK
  if readelf -dW "$1" 2>/dev/null | grep -q RUNPATH; then
    env -u LD_PRELOAD "${PREFIX:-}/glibc/bin/patchelf" --remove-rpath "$1" 2>/dev/null || patchelf --remove-rpath "$1"
  fi
  local strip_in=$1
  if command -v cygpath >/dev/null 2>&1; then strip_in=$(cygpath -w "$1"); fi
  $STRIP --strip-unneeded "$strip_in"
  cp "$1" "$OUT/$2"
  echo "Built $2"
}

[[ -f $TP/proot/src/GNUmakefile && -f $TP/libandroid-shmem/shmem.c ]] \
  || { echo "third_party submodules missing: run git submodule update --init" >&2; exit 1; }
cd "$WORK"
rm -rf talloc libandroid-shmem proot
cp -r "$TP/talloc" talloc
cp -r "$TP/libandroid-shmem" libandroid-shmem
cp -r "$TP/proot" proot
rm -rf libandroid-shmem/.git proot/.git

# talloc: one source file; talloc-config.h answers what its waf configure would have found on Android
T=$WORK/talloc
cp "$HERE/talloc-config.h" config.h
$CC -fPIC -O2 -fvisibility=hidden -D__STDC_WANT_LIB_EXT1__=1 -D_GNU_SOURCE \
  -I. -I"$T" -I"$T/lib/replace" -c "$T/talloc.c" -o talloc.o
$CC -shared -Wl,-soname,libtalloc.so $LDPAGE talloc.o -o lib/libtalloc.so
cp "$T/talloc.h" include/

# libandroid-shmem (its own Makefile's flags). _PATH_TMP is Termux's addition to paths.h, which the NDK lacks: the
# value Termux's clang gives it, so a build is the same with either compiler (it only names where keyed segments link).
S=$WORK/libandroid-shmem
$CC -fpic -std=c11 -O2 -Wall '-D_PATH_TMP="/data/data/com.termux/files/usr/tmp/"' -c "$S/shmem.c" -o shmem.o
$CC -shared -Wl,-soname,libandroid-shmem.so -Wl,--version-script="$S/exports.txt" $LDPAGE shmem.o \
  -o lib/libandroid-shmem.so -llog -landroid
cp "$S/shm.h" include/sys/shm.h

# PRoot, as Termux builds it, with the loader as its own file (Buddy passes its path in PROOT_LOADER).
# One source file gets string.h only through Termux's headers, so it's added for the NDK.
sed -i '1i #include <string.h>' "proot/src/extension/ashmem_memfd/ashmem_memfd.c"
# CPPFLAGS/LDFLAGS go in the environment so the Makefile's own additions still apply. The loader links with its own
# flags, and the NDK's linker would otherwise lay it out for 4 KB pages only.
# Windows (Git Bash + Scoop make): $(shell egrep/clang probes) break when sh lives under
# "C:\Program Files\...". Pre-seed build.h and neutralize those shell lines in the *copy*.
# Put VERSION in build.h (not -DVERSION=\"...\") so MSYS path conversion cannot rewrite /x.y.z.
VERSION_DEFINE="#define VERSION \"$PROOT_VERSION\""
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || -n "${WINDIR:-}" ]]; then
  cat > proot/src/build.h <<EOF
/* This file is auto-generated, edit at your own risk.  */
#ifndef BUILD_H
#define BUILD_H
$VERSION_DEFINE
#define HAVE_PROCESS_VM
#define HAVE_SECCOMP_FILTER
#endif /* BUILD_H */
EOF
  : > proot/src/.check_process_vm.res
  : > proot/src/.check_seccomp_filter.res
  sed -i 's|^USE_BUILD_H :=.*|USE_BUILD_H := cli/cli.o cli/proot.o|' proot/src/GNUmakefile
  sed -i 's|^BUILD_ID_NONE :=.*|BUILD_ID_NONE :=|' proot/src/GNUmakefile
  sed -i 's|^ROSEGMENT :=.*|ROSEGMENT :=|' proot/src/GNUmakefile
  # disable MSYS rewriting args that look like Unix paths (breaks -DVERSION=\"a.b.c\")
  export MSYS2_ARG_CONV_EXCL='*'
  PROOT_CPPFLAGS="-I$WORK/include -DARG_MAX=131072"
  # relative -L from proot/src so Windows lld finds the .so files we just built
  PROOT_LDFLAGS="-L../../lib $LDPAGE"
else
  PROOT_CPPFLAGS="-I$WORK/include -DARG_MAX=131072 -DVERSION=\\\"$PROOT_VERSION\\\""
  PROOT_LDFLAGS="-L$WORK/lib $LDPAGE"
fi
CPPFLAGS="$PROOT_CPPFLAGS" LDFLAGS="$PROOT_LDFLAGS" LOADER_LDFLAGS="$LDPAGE" \
  make -s -C "proot/src" proot loader/loader \
  SHELL=/bin/bash GIT=false CC="$CC" LD="$CC" STRIP="$STRIP" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" HAS_LOADER_32BIT= \
  PROOT_WITH_LIBANDROID_SHMEM=true PROOT_UNBUNDLE_LOADER=/nonexistent

# Windows NDK tools want Win32 paths; cygpath when available.
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"
  else printf '%s' "$1"; fi
}

finish lib/libtalloc.so libtalloc.so
finish lib/libandroid-shmem.so libandroid-shmem.so
finish "proot/src/proot" libproot.so
cp "proot/src/loader/loader" "$OUT/libproot-loader.so"
$STRIP --strip-unneeded "$(winpath "$OUT/libproot-loader.so")" && echo "Built libproot-loader.so"

# the pty helper; jni.h comes with the NDK, or with Termux's JDK on the phone
JNI=()
if command -v javac >/dev/null; then
  J=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")/include
  # skip JNI includes when javac is a Windows path that confuses the NDK
  if [[ -d "$J" ]]; then JNI=(-I"$J" -I"$J/linux"); fi
fi
$CC -shared -fPIC -O2 -Wall $LDPAGE "${JNI[@]}" -o pty.so "$(winpath "$HERE/pty.c")"
finish pty.so libbuddypty.so
