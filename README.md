# osmohdr

> **⚠️ Notice:** This project is largely AI-generated. Expect rough edges.

**osmohdr** turns DJI Osmo Action 6 **D-Log M** footage into **HLG HDR** video that matches the DJI Mimo app's "color restore + HDR" export, with Mimo-style **skin smoothing**, entirely on the Mac GPU. A 4K 59.94p clip converts at about 95 fps on an M1 Max, instead of a long export on the phone.

[中文文档](./README.zh.md)

## Features

- **Mimo-matched color**: a 33-point 3D LUT fitted on pairs of original D-Log M clips and their Mimo HDR exports. On held-out frames it lands within 2.4–4.9 code values of Mimo, versus 41–55 for DJI's generic D-Log M to HLG LUT.
- **HLG with Dolby Vision**: HEVC Main 10 with BT.2020 primaries and the HLG transfer. VideoToolbox attaches a Dolby Vision 8.4 RPU to every frame, as Mimo's export does.
- **Beauty**: skin smoothing and brightening calibrated against Mimo. The skin mask combines Vision person segmentation, face landmarks (eyes, brows, lips and nose are left alone) and a skin color model learned per clip. Smoothing is an edge-preserving guided filter.
- **Fast**: Core Image and Metal kernels, hardware HEVC decode and encode, and three frames in flight. The media engine (about 96 fps for 4K60 HEVC) is the limit, not the GPU. `--jobs` converts several files at once.
- **Faithful container**: audio is copied bit-exact, the capture date is kept, and the source timescale is preserved, so frame steps stay exactly 1001/60000 s.
- **Optional wide-angle correction** (`--pannini`): a Pannini reprojection driven by the 35 mm-equivalent focal length read from the DJI metadata. It is off by default, because for footage the camera has already dewarped it has to enlarge the frame centre by 1.2–1.3x, which visibly softens it.
- **DaVinci Resolve Studio script**: [`resolve/osmo_resolve.py`](./resolve/osmo_resolve.py) batch-renders the same LUT, plus an optional PowerGrade, through Resolve Studio's scripting API.

## Requirements

- Apple Silicon Mac with macOS 15 or later
- Xcode 16 or a Swift 6 toolchain
- Footage recorded in D-Log M on a DJI Osmo Action 6. Other D-Log M cameras can bring their own LUT with `--lut`.

## Build

```bash
git clone https://github.com/bdim404/osmohdr.git
cd osmohdr
swift build -c release
```

The binary is `.build/release/osmohdr`. It loads the built-in LUT from `osmohdr_osmohdr.bundle` next to it, so copy both if you move it.

## Usage

```bash
.build/release/osmohdr ~/Downloads/DJI_20261029_*.MP4
.build/release/osmohdr --jobs 2 -o ~/Movies/HDR ~/Downloads/Action6
```

By default each clip is written to `<input folder>/HDR/<name>_HDR.mov`.

| Option | Default | Description |
| --- | --- | --- |
| `-o`, `--output DIR` | `<input folder>/HDR` | Output folder |
| `--lut FILE` | built-in Mimo match | D-Log M to HLG `.cube` |
| `--beauty X` | `1` | Overall beauty strength, `0` disables it |
| `--smooth X` | `1` | Skin smoothing multiplier |
| `--whiten X` | `1` | Skin brightening multiplier |
| `--pannini X` | `0` | Wide-angle edge stretch correction strength, `1` is full |
| `--focal MM` | DJI metadata, else `15` | 35 mm-equivalent focal length used by `--pannini` |
| `--bitrate MBPS` | `80` | HEVC bitrate |
| `--frames N` | all | Only convert the first N frames |
| `--jobs N` | `2` | Videos converted at the same time |
| `--mask` | off | Render the beauty mask instead of the image |

## How it works

1. AVFoundation decodes the 10-bit 4:2:0 HEVC in hardware, and Core Image converts it to 32-bit float RGB.
2. The 3D LUT maps D-Log M to HLG / BT.2020 code values.
3. On every second frame at 50/60p, a 768 px copy goes through Vision for person segmentation and face landmarks. That yields the person mask, a feature mask for eyes, brows, lips and nose, a face region and an updated skin color model.
4. Metal kernels build the skin mask and run the guided filter at quarter resolution, then blend smoothing and brightening back at full resolution.
5. VideoToolbox encodes HEVC Main 10 with HLG tags and Dolby Vision 8.4 metadata, and the audio is copied unchanged.

## Limitations

- The LUT was fitted on a handful of scenes from one camera. Other scenes, firmware versions or exposure habits may drift from Mimo.
- The beauty pass approximates Mimo's look. It is not DJI's algorithm.
- Wide-angle correction cannot be lossless on footage the camera has already dewarped. For new footage, the camera's **Natural Wide** FOV is the better route.
- Not affiliated with or endorsed by DJI.

## License

osmohdr is released under the [Apache-2.0 License](./LICENSE).
