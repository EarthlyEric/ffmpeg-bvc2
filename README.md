# ffmpeg-bvc2

基于 [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg) 构建、**附加 bytevc2 解码能力**的 FFmpeg。

bytevc2 是字节跳动的私有视频编码（≈ H.266/VVC 的衍生实现）。主线和 jellyfin 的 FFmpeg 都不带它的解码器，
播放这类片源只能报 `codec_name=unknown`。本仓库在上游之上叠加一个约 107 行的小 patch，把
[librempeg](https://github.com/librempeg/librempeg) 的 bvc2 支持移植过来。

## 为什么是 patch 而不是 fork

bvc2 的改动量很小：**15 个文件 / 107 行插入**，而且主体是**复用上游已有的 vvc 解码器**
（`libavcodec/vvc/*` 几乎不用动，librempeg 只是新增了一个 `FFCodec` 入口 + 一个 CBS 类型）。

| | patch（本仓库） | fork 整个 FFmpeg |
| --- | --- | --- |
| 仓库体积 | 几十 KB | 完整 FFmpeg 历史（数 GB） |
| 上游升级 | 改 `UPSTREAM_COMMIT`；patch 对不上**立刻构建失败** | merge；冲突容易静默错位 |
| 代码审查 | 只看这 107 行 | 淹没在 FFmpeg 历史里 |

「patch 对不上就失败」是刻意设计：宁可构建红，也不要静默产出没有 bvc2 的二进制。

## bvc2 的工作原理

关键在于**容器层的差异**，而不是编码算法本身：

1. `libavformat/isom_tags.c` 把 MP4 的 `bvc2` 四字码映射到 `AV_CODEC_ID_BVC2`；
2. `libavcodec/cbs_h266.c` 新增 `ff_cbs_type_bvc2`，它复用 vvc 的 NAL 读写，
   但用**自己的** `cbs_bvc2_split_fragment` —— 该函数**不做 VVCC 头解析**，
   直接把 `bv2C` 里的原始数据按 4 字节长度前缀切分 NAL；
3. `libavcodec/vvc/dec.c` 里把 `ff_cbs_init(&s->cbc, AV_CODEC_ID_VVC, ...)` 改成
   `avctx->codec_id`，让 bvc2 走上面那个 CBS 类型；
4. 另外注册一个 `ff_bvc2_decoder`，其余全部复用 vvc 解码器。

> 这也是为什么「把 `bv2C` 改写成 `vvcC`、把 `bvc2` 改写成 `vvc1`」骗不过去：
> 参数集盒的布局本身不同，vvc 的 VVCC 解析器会在第一步就失败。

## 用法

```bash
# 下载 Release 里的产物，或自己构建
ffmpeg -hide_banner -decoders | grep bvc2      # 应看到 "V....D bvc2  BVC2"
ffmpeg -i input.mp4 -c copy out.mp4            # 纯解封装（若下游能解 bvc2）
ffmpeg -i input.mp4 -c:v libx264 -c:a copy out.mp4   # 转成通用 H.264
```

带 CENC 加密的片源（红果等）加 `-decryption_key <hex>`。

## 构建

CI 会在 `patches/` 或上游变动时自动跑（Linux + Windows）。本地复现：

```bash
bash scripts/prepare.sh /tmp/src          # clone + pin + 打 patch + 接线断言
bash scripts/build.sh   /tmp/src /tmp/dist
```

`scripts/build.sh` 与 CI 用的是同一份命令，本地失败可以直接对着调。

### 上游升级

```bash
# 1. 改 pin
echo <新提交> > UPSTREAM_COMMIT
# 2. 本地验证
bash scripts/prepare.sh /tmp/src
# 3. patch 对不上就按 .rej 修 patches/0001-*.patch，重新验证
```

## 产物内容

| 平台 | 文件 |
| --- | --- |
| Linux x86_64 | `ffmpeg-bvc2-linux64-<sha>.tar.xz` |
| Windows x86_64 | `ffmpeg-bvc2-win64-<sha>.zip` |

启用的部分：`bvc2` / `vvc` / `h264` / `hevc` / `aac` 解码，`libx264` + `aac` 编码，
有 NVENC 环境时另含 `h264_nvenc` / `hevc_nvenc`，容器支持 mp4 / mpegts / hls。

> 编译时用 `--enable-gpl --enable-version3`（bvc2 代码来自 GPLv3 的 librempeg，
> 且 x264 本身是 GPL）。因此产物是 **GPLv3**，分发时需一并提供对应源码——即本仓库 + 上游提交。

## 许可

本仓库的 patch 来自 [librempeg](https://github.com/librempeg/librempeg)（作者 Paul B Mahol，GPLv3），
上游是 [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg)。构建产物因包含 GPL 组件，
按 GPLv3 分发。详见 `LICENSE`。
