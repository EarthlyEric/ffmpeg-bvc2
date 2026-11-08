#!/usr/bin/env bash
# 把上游 checkout 到 UPSTREAM_COMMIT 并应用 patches/。
#
# 用法: prepare.sh <上游目录>
#
# 与 workflow 里的步骤保持同一份逻辑：本地要能一条命令复现 CI 的行为。
set -euo pipefail

DEST="${1:?用法: prepare.sh <上游目录>}"
# 按脚本自身位置解析仓库根，不依赖调用者的 cwd。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPO="${UPSTREAM_REPO:-https://github.com/jellyfin/jellyfin-ffmpeg.git}"
BRANCH="${UPSTREAM_BRANCH:-jellyfin}"
COMMIT="${UPSTREAM_COMMIT_OVERRIDE:-$(tr -d '[:space:]' < "$ROOT/UPSTREAM_COMMIT")}"

# DEST 也规范成绝对路径，避免后续 cd 之后相对路径失效。
case "$DEST" in
    /*) ;;
    *) DEST="$(pwd)/$DEST" ;;
esac

if [ ! -f "$ROOT/UPSTREAM_COMMIT" ]; then
    echo "错误: 找不到 $ROOT/UPSTREAM_COMMIT" >&2
    exit 1
fi

echo "上游: $REPO ($BRANCH)"
echo "提交: $COMMIT"

if [ ! -d "$DEST/.git" ]; then
    # 目标目录可能存在但为空/残缺（上次中断、或被当成临时目录用过）。
    # git clone 拒绝非空目录，所以先清干净再 clone。
    if [ -d "$DEST" ]; then
        rm -rf "$DEST"
    fi
    mkdir -p "$(dirname "$DEST")"
    git clone --filter=blob:none --branch "$BRANCH" "$REPO" "$DEST"
fi
git -C "$DEST" fetch --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$DEST" checkout --force "$COMMIT"
git -C "$DEST" clean -fdx -q

shopt -s nullglob
patches=("$ROOT"/patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "错误: patches/ 下没有 patch，产物将不含 bvc2" >&2
    exit 1
fi
for p in "${patches[@]}"; do
    echo "==> 应用 $(basename "$p")"
    # 关键: 传给 git 的必须是**相对路径**。
    # git.exe 在 Windows 上是原生程序，不认 MSYS 的 `/h/...` 挂载路径
    # （bash 能 ls 到，git 却报 can't open patch），只有相对路径两边都成立。
    relative="$(realpath --relative-to="$DEST" "$p" 2>/dev/null || echo "$p")"
    ( cd "$DEST" && git apply --3way --verbose "$relative" )
done

# 断言接线完整：防止「patch 打上了但没接进构建系统」的静默失败。
cd "$DEST"
grep -q 'cbs_bvc2' configure
grep -q 'bvc2_decoder_select' configure
grep -q 'CONFIG_BVC2_DECODER' libavcodec/vvc/Makefile
grep -q 'ff_bvc2_decoder' libavcodec/vvc/dec.c
grep -q 'ff_bvc2_decoder' libavcodec/allcodecs.c
grep -q 'ff_cbs_type_bvc2' libavcodec/cbs_h266.c
grep -q 'AV_CODEC_ID_BVC2' libavcodec/codec_id.h
grep -q 'AV_CODEC_ID_BVC2' libavformat/isom_tags.c
echo "bvc2 接线完整"
