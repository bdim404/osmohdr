# osmohdr

> **⚠️ 提示：** 这个项目大部分由 AI 生成，可能还有不少粗糙的地方。

**osmohdr** 把大疆 Osmo Action 6 拍的 **D-Log M** 素材转换成 **HLG HDR** 视频，色彩对齐大疆 Mimo App 里「色彩还原 + HDR」的导出效果，还带 Mimo 风格的**美颜磨皮**，全部在 Mac 的 GPU 上完成。一段 4K 59.94p 的视频在 M1 Max 上大约每秒处理 95 帧，不用再在手机上慢慢等导出。

[English](./README.md)

## 功能

- **对齐 Mimo 的色彩**：用原始 D-Log M 素材和对应的 Mimo HDR 导出成对拟合出一个 33 点的 3D LUT。在没参与拟合的帧上，和 Mimo 的差距只有 2.4–4.9 个码值，而大疆通用的 D-Log M 转 HLG LUT 差 41–55 个码值。
- **HLG + 杜比视界**：输出 HEVC Main 10，BT.2020 色域，HLG 传递函数。VideoToolbox 会给每一帧附上杜比视界 8.4 元数据，和 Mimo 导出的一样。
- **美颜**：磨皮和提亮都对着 Mimo 校准过。皮肤遮罩结合了 Vision 的人像分割、人脸关键点（眼睛、眉毛、嘴唇和鼻子不会被处理）以及每段视频单独学习的肤色模型，磨皮用的是保边的引导滤波。
- **快**：Core Image + Metal 内核，硬件 HEVC 解码和编码，同时有三帧在流水线里。瓶颈在媒体引擎（4K60 HEVC 大约 96 fps），而不是 GPU。`--jobs` 可以同时转多个文件。
- **保留原始信息**：音频原样复制，保留拍摄时间，保留源文件的时间基，每帧间隔严格是 1001/60000 秒。
- **可选的广角校正**（`--pannini`）：Pannini 重投影，等效焦距从大疆的元数据里自动读取。默认关闭，因为对相机已经做过直线化的素材，它必须把画面中间放大 1.2–1.3 倍，中间会明显变软。
- **达芬奇 Studio 脚本**：[`resolve/osmo_resolve.py`](./resolve/osmo_resolve.py) 通过 Resolve Studio 的脚本 API 批量套用同一个 LUT（还可以加一个 PowerGrade）并渲染。

## 环境要求

- Apple Silicon 的 Mac，macOS 15 或更新
- Xcode 16 或 Swift 6 工具链
- 用大疆 Osmo Action 6 以 D-Log M 录制的素材。其他 D-Log M 相机可以用 `--lut` 换成自己的 LUT。

## 编译

```bash
git clone https://github.com/bdim404/osmohdr.git
cd osmohdr
swift build -c release
```

编译出来的程序在 `.build/release/osmohdr`。它会从旁边的 `osmohdr_osmohdr.bundle` 读取内置 LUT，挪位置的话两个要一起挪。

## 使用

```bash
.build/release/osmohdr ~/Downloads/DJI_20261029_*.MP4
.build/release/osmohdr --jobs 2 -o ~/Movies/HDR ~/Downloads/Action6
```

默认每个视频输出到 `<输入文件夹>/HDR/<文件名>_HDR.mov`。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-o`, `--output DIR` | `<输入文件夹>/HDR` | 输出文件夹 |
| `--lut FILE` | 内置的 Mimo 匹配 LUT | D-Log M 转 HLG 的 `.cube` |
| `--beauty X` | `1` | 美颜总强度，`0` 关闭 |
| `--smooth X` | `1` | 磨皮强度倍数 |
| `--whiten X` | `1` | 提亮强度倍数 |
| `--pannini X` | `0` | 广角边缘拉伸校正强度，`1` 为完全校正 |
| `--focal MM` | 读取大疆元数据，读不到用 `15` | `--pannini` 使用的 35mm 等效焦距 |
| `--bitrate MBPS` | `80` | HEVC 码率 |
| `--frames N` | 全部 | 只转换前 N 帧 |
| `--jobs N` | `2` | 同时转换的视频数量 |
| `--mask` | 关闭 | 输出美颜遮罩而不是画面 |

## 工作原理

1. AVFoundation 用硬件解码 10-bit 4:2:0 的 HEVC，Core Image 把它转成 32 位浮点 RGB。
2. 3D LUT 把 D-Log M 映射到 HLG / BT.2020 码值。
3. 50/60p 的视频每两帧取一帧，缩到 768 像素宽交给 Vision 做人像分割和人脸关键点检测，得到人像遮罩、五官遮罩（眼睛、眉毛、嘴唇、鼻子）、脸部区域，并更新肤色模型。
4. Metal 内核生成皮肤遮罩，在四分之一分辨率上做引导滤波，再在原分辨率上把磨皮和提亮混合回去。
5. VideoToolbox 编码成带 HLG 标记和杜比视界 8.4 元数据的 HEVC Main 10，音频原样复制。

## 局限

- LUT 只用一台相机的几个场景拟合，换场景、固件版本或曝光习惯，可能会和 Mimo 有偏差。
- 美颜是对 Mimo 效果的近似，不是大疆的算法。
- 对相机已经直线化的素材，广角校正不可能无损。新拍的素材建议直接用相机里的 **Natural Wide** 视角。
- 与大疆无关，也没有得到大疆的认可。

## 许可证

osmohdr 以 [Apache-2.0 许可证](./LICENSE) 发布。
