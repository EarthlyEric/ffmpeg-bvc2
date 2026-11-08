#!/bin/sh
# 构建「jellyfin-ffmpeg + bytevc2」。
#
# 用法: build.sh <源目录> <输出目录>
#
# 为什么要有这个脚本而不是把 configure 参数写进 workflow：
# 本地复现 CI 失败时，直接跑同一条命令即可，不必猜 workflow 拼出来的参数。
set -eu

SRC="${1:?用法: build.sh <源目录> <输出目录>}"
DEST="${2:?用法: build.sh <源目录> <输出目录>}"

cd "$SRC"

# configure 必须可执行。上游 checkout 出来是 755，但经过 upload-artifact/download-artifact
# 往返后 mode 位会丢失（Linux CI 实测 exit 126: Permission denied），所以显式补上。
chmod +x ./configure 2>/dev/null || true

# ── 工具链 ───────────────────────────────────────────────────────────────
# Windows 走 CLANG64，与 jellyfin-ffmpeg 官方一致（.github/workflows/_meta_win_clang_portable.yaml
# 用 mingw-w64-clang-x86_64-toolchain）。不是 gcc：
#   - clang64 默认动态链接 libc++.dll，而我们要单文件 exe，所以显式 -static
#   - 上游还把 libc++.a / libunwind.a 拷进自建 prefix，这里用 -static 达到同样效果
CC_FLAGS=""
STATIC_FLAGS="--enable-static --disable-shared"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        if command -v clang >/dev/null 2>&1; then
            CC_FLAGS="--cc=clang --cxx=clang++"
            echo "工具链: clang ($(clang --version | head -1))"
        else
            echo "工具链: 未找到 clang，回退 gcc（与 jellyfin 官方不一致，仅作兜底）"
        fi
        # 单文件 exe：把 libc++ / libgcc / winpthread 全静态链进来。
        STATIC_FLAGS="--enable-static --disable-shared --extra-ldflags=-static"
        ;;
    Linux)
        echo "工具链: gcc ($(cc --version | head -1))"
        ;;
esac

# ── 可选依赖探测 ─────────────────────────────────────────────────────────
# 原则：**探测到才启用**。configure 里写死 --enable-libx264 而系统没这个库时
# 会直接失败而不是跳过，所以每个可选依赖都要先判存在。
pkg_exists() {
    pkg-config --exists "$1" 2>/dev/null
}

X264_FLAGS=""
X264_ENCODERS=""
if pkg_exists x264; then
    X264_FLAGS="--enable-libx264"
    X264_ENCODERS=",libx264"
    echo "libx264: $(pkg-config --modversion x264)"
else
    echo "libx264: 未找到（转码将只有硬件编码器可用）"
fi

# 硬件编码器是这次自建的主要动机之一：librempeg 的预编译件只有 libx264 软编，
# 1080p 转码约 0.5x 实时（一集 106 秒要等 55 秒）。开 NVENC 后同一台机器约 11x。
NVENC_FLAGS=""
NVENC_ENCODERS=""
FFNVCODEC_HEADER=""
for candidate in \
    "${FFNVCODEC_PREFIX:-}/include/ffnvcodec/nvEncodeAPI.h" \
    "/usr/include/ffnvcodec/nvEncodeAPI.h" \
    "/clang64/include/ffnvcodec/nvEncodeAPI.h" \
    "/ucrt64/include/ffnvcodec/nvEncodeAPI.h" \
    "/mingw64/include/ffnvcodec/nvEncodeAPI.h"
do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { FFNVCODEC_HEADER="$candidate"; break; }
done

if [ -n "$FFNVCODEC_HEADER" ]; then
    NVENC_FLAGS="--enable-nvenc --enable-ffnvcodec"
    NVENC_ENCODERS=",h264_nvenc,hevc_nvenc"
    echo "NVENC: 找到 $FFNVCODEC_HEADER，启用硬件编码器"
else
    echo "NVENC: 未找到 ffnvcodec 头文件，仅使用软件编码"
fi

# 一个编码器都没有时构建出来没法转码，直接失败比产出废件好。
if [ -z "$X264_ENCODERS$NVENC_ENCODERS" ]; then
    echo "错误: 既没有 libx264 也没有 NVENC，产物无法转码" >&2
    exit 1
fi

./configure \
    --prefix="$DEST" \
    --extra-version=bvc2 \
    --disable-doc \
    --disable-debug \
    --enable-gpl \
    --enable-version3 \
    $STATIC_FLAGS \
    --enable-network \
    --disable-ffplay \
    $CC_FLAGS \
    $X264_FLAGS \
    $NVENC_FLAGS \
    --enable-decoder=bvc2,vvc,h264,hevc,aac,flac,mp3,ac3,eac3,opus,vorbis,pcm_s16le \
    --enable-encoder=aac${X264_ENCODERS}${NVENC_ENCODERS} \
    --enable-demuxer=mov,mpegts,hls,matroska,mp3,wav,flac,ogg \
    --enable-muxer=mp4,mpegts,hls,matroska,null,mp3,wav \
    --enable-protocol=file,http,https,tcp,tls,crypto,pipe \
    --enable-parser=h264,hevc,vvc,aac \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,vvc_mp4toannexb,aac_adtstoasc \
    --enable-filter=scale,format,aresample,atrim,trim,crop,transpose,null \
    --enable-swscale \
    --enable-swresample \
    --enable-avfilter

echo "=== 配置中的 bvc2 相关开关 ==="
grep -E 'CONFIG_(BVC2_DECODER|CBS_BVC2)\b' ffbuild/config.mak | sort -u || true

# 这是硬断言：patch 打上了但没接进构建系统（或 configure 判断依赖不满足而
# 静默关掉）时，宁可这里失败，也不要产出没有 bvc2 的二进制。
if ! grep -q 'CONFIG_BVC2_DECODER=yes' ffbuild/config.mak; then
    echo "错误: 配置里没有启用 CONFIG_BVC2_DECODER，构建产物不会含 bvc2" >&2
    exit 1
fi

make -j"$(nproc 2>/dev/null || echo 4)"
make install

echo "=== 产物能力检查 ==="
"$DEST/bin/ffmpeg" -hide_banner -decoders | grep -E '\bbvc2\b' || {
    echo "错误: 产物 ffmpeg 不含 bvc2 解码器" >&2
    exit 1
}
"$DEST/bin/ffmpeg" -hide_banner -encoders | grep -E 'nvenc|libx264' || {
    echo "错误: 产物没有任何可用的视频编码器" >&2
    exit 1
}
