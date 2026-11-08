# patches/

## 0001-add-bvc2-decoder.patch

给 jellyfin-ffmpeg 加上 bytevc2 解码能力。**15 个文件 / 107 行插入**。

### 来源

移植自 [librempeg](https://github.com/librempeg/librempeg) 的两个提交（作者 Paul B Mahol）：

| 提交 | 内容 |
| --- | --- |
| `c0984cae71` (2025-11-27) `avcodec: add BVC2 decoder` | 主体：codec id / descriptor / CBS / vvc 入口 / isom tag |
| `54e926c86b` (2026-02-24) `avcodec: add back BVC2 support` | `cbs_bvc2_split_fragment` + `ff_cbs_type_bvc2`（拆分后的 CBS 布局） |

**不能直接 cherry-pick**：jellyfin-ffmpeg 8.1.3 的 `libavutil` 是 60.x，librempeg master 是 61.x；
而且 librempeg 的首个提交写的是**拆分前**的 `cbs_h2645.c` 单文件布局，jellyfin 已经拆成
`cbs_h264.c` / `cbs_h265.c` / `cbs_h266.c`。所以本 patch 是按 jellyfin 的实际布局**手工重写**的，
不是 git 导出的原始 diff。

### 改动清单

| 文件 | 改动 |
| --- | --- |
| `configure` | `CONFIG_EXTRA` 加 `cbs_bvc2`；`cbs_bvc2_select`；`bvc2_decoder_select="cabac cbs_bvc2 golomb videodsp vvc_sei"` |
| `libavcodec/Makefile` | `OBJS-$(CONFIG_CBS_BVC2)` + `OBJS-$(CONFIG_BVC2_DECODER)` |
| `libavcodec/codec_id.h` | 新增 `AV_CODEC_ID_BVC2` |
| `libavcodec/codec_desc.c` | 新增 bvc2 描述（复用 `ff_vvc_profiles`） |
| `libavcodec/allcodecs.c` | `extern const FFCodec ff_bvc2_decoder` |
| `libavcodec/cbs_internal.h` | `CBS_BVC2` 宏 + `type_bvc2` 声明 |
| `libavcodec/cbs.c` | 类型表与 codec id 表各加一项 |
| `libavcodec/cbs_h266.c` | `cbs_bvc2_split_fragment()` + `ff_cbs_type_bvc2`（**核心**） |
| `libavcodec/cbs_h2645.c` | `ff_cbs_h2645_unit_requires_zero_byte` 认 BVC2 |
| `libavcodec/cbs_sei.c` | `ff_cbs_sei_find_type` 的 H266 分支并入 BVC2 |
| `libavcodec/h2645_parse.c` | NAL 头按 VVC 规则解析 |
| `libavcodec/vvc/dec.c` | `ff_cbs_init(ctx->codec_id)` + `ff_bvc2_decoder` 注册 |
| `libavcodec/vvc/Makefile` | bvc2 复用 vvc 的 15 个 .o |
| `libavformat/cbs.h` | `CBS_BVC2 0` |
| `libavformat/isom_tags.c` | `bvc2` 四字码 → `AV_CODEC_ID_BVC2` |

### 关键设计点

`cbs_bvc2_split_fragment` **不做 VVCC 头解析**，而是直接把 `bv2C` 盒里的数据按 4 字节长度前缀切 NAL。
这是 bvc2 与 vvc 唯一的容器层差异——也解释了为什么「把 `bv2C` 改写成 `vvcC`」骗不过去：
参数集的布局本身不同，vvc 的解析器第一步就会 reject。

`ff_cbs_init(&s->cbc, avctx->codec_id, avctx)` 是把硬编码的 `AV_CODEC_ID_VVC` 换成
`avctx->codec_id`，让 bvc2 能选中自己的 CBS 类型。**这行是整条链路的枢纽**，
上游若重构该调用点，patch 会失败——正是想要的告警。

### 维护

上游升级用 `bash scripts/prepare.sh` 验证；`git apply --3way` 失败时按 `.rej` 手工修本 patch。

### 许可

源自 GPLv3 的 librempeg。因此构建必须带 `--enable-gpl --enable-version3`，产物按 GPLv3 分发。
