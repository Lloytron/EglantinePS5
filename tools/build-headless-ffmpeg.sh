#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(cat "$root/.local/headless-cache")
[[ "$(cat "$scratch/owner")" == "$root" ]]
export PS5_PAYLOAD_SDK="$scratch/sdk"
source="$scratch/source/.cache/cpm/ffmpeg/c7b5f1537d"
test -f "$source/configure"
mkdir -p "$scratch/ffmpeg-native"
prefix="$scratch/ffmpeg-native/install"

# libdav1d for AV1: Switch 2 titles play AV1 movies (Ocarina of Time's title screen) and Lichii's
# own FFmpeg packages merge libdav1d into avcodec for them. Same pinned release as Lichii's.
dav1d_version=1.5.4
dav1d_sha256=a1d5b63d2d38ec9bd03acf643caa51fa22edd1e89c5a109c4807717216bbec07
downloads=${EGLANTINEPS5_DEPS_CACHE:-$HOME/.cache/eglantineps5-deps}
mkdir -p "$downloads"
dav1d_archive="$downloads/dav1d-$dav1d_version.tar.gz"
if [[ ! -f $dav1d_archive ]] || ! echo "$dav1d_sha256  $dav1d_archive" | sha256sum -c --quiet; then
    curl -fsSL --retry 3 -o "$dav1d_archive.part" \
        "https://code.videolan.org/videolan/dav1d/-/archive/$dav1d_version/dav1d-$dav1d_version.tar.gz"
    echo "$dav1d_sha256  $dav1d_archive.part" | sha256sum -c --quiet
    mv "$dav1d_archive.part" "$dav1d_archive"
fi
rm -rf "$scratch/dav1d-src" "$scratch/dav1d-build"
mkdir -p "$scratch/dav1d-src"
tar -xzf "$dav1d_archive" -C "$scratch/dav1d-src" --strip-components=1
cat > "$scratch/dav1d-cross.ini" <<CROSS
[binaries]
c = ['bash', '$root/tools/ffmpeg-ps5-cc.sh']
ar = 'llvm-ar-18'
strip = 'llvm-strip-18'
nasm = 'nasm'
pkg-config = 'false'

[host_machine]
system = 'freebsd'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
CROSS
meson setup "$scratch/dav1d-build" "$scratch/dav1d-src" --cross-file "$scratch/dav1d-cross.ini" \
    --prefix="$prefix" --libdir=lib --buildtype=release -Ddefault_library=static \
    -Denable_tools=false -Denable_examples=false -Denable_tests=false -Dlogging=false
meson compile -C "$scratch/dav1d-build" -j "${EDEN_BUILD_JOBS:-$(nproc)}"
meson install -C "$scratch/dav1d-build"
# Meson follows FreeBSD here and puts dav1d.pc in libdata/pkgconfig.
test -f "$prefix/lib/libdav1d.a" && test -f "$prefix/libdata/pkgconfig/dav1d.pc"

cd "$scratch/ffmpeg-native"
# Use the same pinned, minimal decoder set as the Linux core, plus libdav1d for AV1. Avoid the full
# prebuilt FFmpeg package's unrelated codec and C++ runtime dependencies.
PKG_CONFIG_LIBDIR="$prefix/libdata/pkgconfig:$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
bash "$source/configure" --prefix="$prefix" \
    --enable-cross-compile --arch=x86_64 --target-os=freebsd \
    --cc="bash $root/tools/ffmpeg-ps5-cc.sh" --ld="bash $root/tools/ffmpeg-ps5-cc.sh" \
    --ar=llvm-ar-18 --ranlib=llvm-ranlib-18 --nm=llvm-nm-18 \
    --disable-autodetect --disable-everything --disable-programs --disable-doc \
    --disable-avdevice --disable-avformat --disable-network --disable-swresample \
    --enable-libdav1d --pkg-config=pkg-config --pkg-config-flags=--static \
    --enable-decoder=h264,vp8,vp9,libdav1d --enable-filter=yadif,scale --enable-pic \
    --enable-pthreads --disable-shared --enable-static
grep -qs 'CONFIG_LIBDAV1D_DECODER 1' config_components.h config.h || { echo 'FFmpeg configured without libdav1d' >&2; exit 1; }
make -j"${EDEN_BUILD_JOBS:-$(nproc)}"
make install
# Merge libdav1d into libavcodec, as Lichii's AV1 FFmpeg packages do, so every link of avcodec
# (FFMPEG_DIR in tools/build-headless-native.sh) gets it without a separate library.
llvm-ar-18 -M <<MRI
create $prefix/lib/libavcodec.merged.a
addlib $prefix/lib/libavcodec.a
addlib $prefix/lib/libdav1d.a
save
end
MRI
mv "$prefix/lib/libavcodec.merged.a" "$prefix/lib/libavcodec.a"
llvm-nm-18 "$prefix/lib/libavcodec.a" 2>/dev/null | grep -q ' T dav1d_send_data$' ||
    { echo 'libdav1d was not merged into libavcodec' >&2; exit 1; }
