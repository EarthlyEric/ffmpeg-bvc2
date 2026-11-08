#!/bin/sh
# 构建「jellyfin-ffmpeg + bytevc2」。
#
# 用法: build.sh <源目录> <输出目录>
#
# 环境变量:
#   NV_CODEC_HEADERS_VERSION  已安装的 nv-codec-headers 版本（仅用于诊断输出）
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

# ── Windows 大小写陷阱：libc++ 的 <version> 撞上 FFmpeg 的 VERSION ──────────
# Windows 文件系统大小写不敏感，于是 libc++ 的 `#include <version>` 会命中仓库根目录
# 的 `VERSION` 文件（它是一行纯文本版本号），编译报：
#   ./version:1:1: error: expected unqualified-id
# 实测 CLANG64 构建必炸在这里。上游 msys2/build.sh 用改名 + 改 version.sh 规避，
# 这里照做。只在 MINGW/MSYS 下执行，Linux 不受影响。
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        if [ -f VERSION ] && [ -f ffbuild/version.sh ]; then
            if [ ! -f VERSION.bak ]; then
                mv VERSION VERSION.bak
            fi
            # version.sh 里用 `cat VERSION` 读版本号，改名后要跟着指过去。
            sed -i 's/cat VERSION/cat VERSION.bak/g' ffbuild/version.sh
            echo "Windows 大小写规避: VERSION -> VERSION.bak（避免 libc++ <version> 误命中）"
        fi
        ;;
esac

# ── 工具链 ───────────────────────────────────────────────────────────────
# Windows 走 CLANG64，与 jellyfin-ffmpeg 官方一致（.github/workflows/_meta_win_clang_portable.yaml
# 用 mingw-w64-clang-x86_64-toolchain）。不是 gcc：
#   - clang64 默认动态链接 libc++.dll，而我们要单文件 exe，所以显式 -static
#   - 上游还把 libc++.a / libunwind.a 拷进自建 prefix，这里用 -static 达到同样效果
CC_FLAGS=""
STATIC_FLAGS="--enable-static --disable-shared"
PKGCONFIG_FLAGS=""
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
        # ⚠️ 必须带 --static：MSYS2 的 x264 同时有 .dll.a（动态导入库）和 .a。
        # 不带这个参数时 pkg-config 给出 -lx264 指向导入库，配上上面的 -static
        # 链接探测就会失败，configure 报 "ERROR: x264 not found using pkg-config"。
        # 上游的 msys2/build.sh 用的就是这一行。
        PKGCONFIG_FLAGS="--pkg-config-flags=--static"
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
    # 报出编进二进制的 NVENC API 版本。这是一次真实事故的产物：
    # 用 nv-codec-headers master（API 13.1）构建出的 ffmpeg，在驱动 572.83
    # （只支持到 13.0）的机器上会直接失败：
    #   Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0
    # 而编码器探测又会把这种失败当成「没有硬件编码器」静默回退软编，
    # 表面上只是变慢，很容易被误判成别的原因。
    api_major=$(sed -n 's/^#define NVENCAPI_MAJOR_VERSION \([0-9]*\)/\1/p' "$FFNVCODEC_HEADER" | head -1)
    api_minor=$(sed -n 's/^#define NVENCAPI_MINOR_VERSION \([0-9]*\)/\1/p' "$FFNVCODEC_HEADER" | head -1)
    echo "NVENC: 找到 $FFNVCODEC_HEADER，启用硬件编码器（API ${api_major:-?}.${api_minor:-?}）"
    echo "NVENC: 该 API 版本要求驱动不低于对应 Video Codec SDK 的最低版本；" \
         "13.0 对应 570 系列，13.1 要求 610+。老驱动会静默回退软编。"
else
    echo "NVENC: 未找到 ffnvcodec 头文件，仅使用软件编码"
fi

# 一个编码器都没有时构建出来没法转码，直接失败比产出废件好。
if [ -z "$X264_ENCODERS$NVENC_ENCODERS" ]; then
    echo "错误: 既没有 libx264 也没有 NVENC，产物无法转码" >&2
    exit 1
fi

# ── 字幕渲染（libass）─────────────────────────────────────────────────────
# 为什么加它：系统版 jellyfin-ffmpeg 有 subtitles/ass 滤镜，自建版原先没有，
# 这让「用 bin/ 下的自建版替换系统版」出现能力缺口。
#
# libass 的依赖链：libass → freetype2 + fribidi + fontconfig + harfbuzz。
#
# ⚠️ 只查 pkg-config 存在是不够的 —— 这是踩过的坑：MSYS2 的 fontconfig
# 有 .pc 却**没有静态库**，configure 报
#   ERROR: fontconfig not found using pkg-config
# 而我们的预检还打印着 "fontconfig: 2.18.3"，白白多跑一轮 CI。
# 根因是 FFmpeg 的 require_pkg_config 会真编真链，静态场景下必须有 .a。
# （对照：jellyfin 自己用 --default-library=static 重编了 fontconfig。）
#
# 所以这里做**真实静态链接探测**：能编过才算依赖齐全。
can_static_link() {
    _name="$1"; _header="$2"; _symbol="$3"
    pkg_exists "$_name" || return 1
    _cflags=$(pkg-config --cflags "$_name" 2>/dev/null || true)
    _libs=$(pkg-config --libs --static "$_name" 2>/dev/null || true)
    [ -n "$_libs" ] || return 1
    _tmp=$(mktemp -d 2>/dev/null || echo "/tmp/bvc2probe.$$")
    mkdir -p "$_tmp" 2>/dev/null || true
    cat > "$_tmp/probe.c" <<PROBE
#include <$_header>
int main(void) { (void)&$_symbol; return 0; }
PROBE
    if ${CC:-cc} $_cflags "$_tmp/probe.c" $_libs -o "$_tmp/probe" >/dev/null 2>&1; then
        rm -rf "$_tmp"
        return 0
    fi
    rm -rf "$_tmp"
    return 1
}

SUB_FLAGS=""
SUB_FILTERS=""
missing_sub=""
# 顺序按依赖链，fontconfig 最可能缺静态库，放在前面便于日志判读。
for spec in "freetype2:freetype2/ft2build.h:FT_Init_FreeType" \
            "fribidi:fribidi/fribidi.h:fribidi_version_info" \
            "fontconfig:fontconfig/fontconfig.h:FcInit" \
            "harfbuzz:hb.h:hb_version" \
            "libass:ass/ass.h:ass_library_init"
do
    dep=${spec%%:*}; rest=${spec#*:}; header=${rest%%:*}; symbol=${rest#*:}
    if ! can_static_link "$dep" "$header" "$symbol"; then
        missing_sub="$missing_sub $dep"
    fi
done
if [ -z "$missing_sub" ]; then
    SUB_FLAGS="--enable-libfreetype --enable-libfribidi --enable-libfontconfig --enable-libharfbuzz --enable-libass"
    SUB_FILTERS=",subtitles,ass"
    echo "libass: $(pkg-config --modversion libass)，静态链接探测通过（含 freetype2/fribidi/fontconfig/harfbuzz）"
else
    # 不致命：没有字幕渲染不影响播放与转码，如实报出来即可。
    echo "libass: 跳过 —— 这些依赖通过不了**静态链接**探测:$missing_sub"
    echo "libass: 产物将没有 subtitles/ass 滤镜（字幕不影响播放与转码）"
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
    $PKGCONFIG_FLAGS \
    $X264_FLAGS \
    $NVENC_FLAGS \
    $SUB_FLAGS \
    --enable-decoder=bvc2,vvc,h264,hevc,aac,flac,mp3,ac3,eac3,opus,vorbis,pcm_s16le \
    --enable-encoder=aac${X264_ENCODERS}${NVENC_ENCODERS} \
    --enable-demuxer=mov,mpegts,hls,matroska,mp3,wav,flac,ogg \
    --enable-muxer=mp4,mpegts,hls,matroska,null,mp3,wav \
    --enable-protocol=file,http,https,tcp,tls,crypto,pipe \
    --enable-parser=h264,hevc,vvc,aac \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,vvc_mp4toannexb,aac_adtstoasc \
    --enable-filter=scale,format,aresample,atrim,trim,crop,transpose,null${SUB_FILTERS} \
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

# 字幕：依赖齐备时必须真的有滤镜；缺依赖时允许没有，但要如实标注，
# 避免「以为编进去了其实没有」。
if [ -n "$SUB_FLAGS" ]; then
    for f in subtitles ass; do
        if ! "$DEST/bin/ffmpeg" -hide_banner -filters 2>/dev/null | grep -qE "\b$f\b"; then
            echo "错误: 依赖齐全但产物缺少 $f 滤镜" >&2
            exit 1
        fi
    done
    echo "字幕滤镜: subtitles / ass 已就位"
else
    echo "字幕滤镜: 本产物不含（构建时缺依赖，见上文 libass 行）"
fi
