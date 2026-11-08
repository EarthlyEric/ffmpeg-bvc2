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

# 硬件编码器是这次自建的主要动机之一：librempeg 的预编译件只有 libx264 软编，
# 1080p 转码约 0.5x 实时（一集 106 秒要等 55 秒）。开 NVENC 后同一台机器约 11x。
NVENC_FLAGS=""
NVENC_ENCODERS=""
# ffnvcodec 头文件位置：Linux 装在 /usr，MSYS2 在 mingw 前缀下。
FFNVCODEC_HEADER=""
for candidate in \
    "${FFNVCODEC_PREFIX:-}/include/ffnvcodec/nvEncodeAPI.h" \
    "/usr/include/ffnvcodec/nvEncodeAPI.h" \
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
    # 没有 ffnvcodec 时**必须**连 --enable-encoder=h264_nvenc 一起去掉，
    # 否则 configure 会因依赖缺失直接失败（而不是跳过）。
    echo "NVENC: 未找到 ffnvcodec 头文件，仅使用 libx264 软编"
fi

./configure \
    --prefix="$DEST" \
    --extra-version=bvc2 \
    --disable-doc \
    --disable-debug \
    --enable-gpl \
    --enable-version3 \
    --enable-static \
    --disable-shared \
    --enable-network \
    --disable-ffplay \
    --enable-libx264 \
    $NVENC_FLAGS \
    --enable-decoder=bvc2,vvc,h264,hevc,aac,flac,mp3,ac3,eac3,opus,vorbis,pcm_s16le \
    --enable-encoder=libx264,aac${NVENC_ENCODERS} \
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
grep -E 'CONFIG_(BVC2_DECODER|CBS_BVC2)\b' config.h | sort -u || true

if ! grep -q 'CONFIG_BVC2_DECODER=yes' ffbuild/config.mak; then
    echo "错误: 配置里没有启用 CONFIG_BVC2_DECODER，构建产物不会含 bvc2" >&2
    exit 1
fi

make -j"$(nproc 2>/dev/null || echo 4)"
make install

echo "=== 产物 bvc2 解码器检查 ==="
"$DEST/bin/ffmpeg" -hide_banner -decoders | grep -E '\bbvc2\b' || {
    echo "错误: 产物 ffmpeg 不含 bvc2 解码器" >&2
    exit 1
}
"$DEST/bin/ffmpeg" -hide_banner -encoders | grep -E 'nvenc' || {
    echo "提示: 未启用硬件编码器（仅影响转码速度，不影响 bvc2 解码）"
}
