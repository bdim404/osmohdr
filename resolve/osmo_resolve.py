#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
import time

MODULES = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"
FUSIONSCRIPT = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
RESOLVE_BIN = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/MacOS/Resolve"
LUT_ROOT = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"
DEFAULT_LUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "osmohdr", "Resources", "mimo_ac6_dlogm_hlg.cube")
VIDEO_EXTS = {".mp4", ".mov"}


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def connect(timeout):
    os.environ.setdefault("RESOLVE_SCRIPT_LIB", FUSIONSCRIPT)
    sys.path.append(MODULES)
    import DaVinciResolveScript as dvr

    resolve = dvr.scriptapp("Resolve")
    if resolve:
        return resolve
    if subprocess.run(["pgrep", "-x", "Resolve"], capture_output=True).returncode != 0:
        subprocess.Popen([RESOLVE_BIN, "-nogui"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(3)
        resolve = dvr.scriptapp("Resolve")
        if resolve:
            return resolve
    fail("cannot reach DaVinci Resolve from this script. External scripting needs DaVinci Resolve Studio, "
         "with Preferences > System > General > External scripting using set to Local.")


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(os.path.join(p, f) for f in os.listdir(p)
                            if os.path.splitext(f)[1].lower() in VIDEO_EXTS and not f.startswith("."))
        elif os.path.isfile(p):
            files.append(p)
        else:
            print(f"skip missing {p}", file=sys.stderr)
    return [os.path.abspath(f) for f in files]


def install_lut(path):
    folder = os.path.join(LUT_ROOT, "osmohdr")
    os.makedirs(folder, exist_ok=True)
    shutil.copyfile(path, os.path.join(folder, os.path.basename(path)))
    return "osmohdr/" + os.path.basename(path)


def probe_format(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate",
                              "-of", "csv=p=0", path], capture_output=True, text=True, timeout=30).stdout.strip().split(",")
        num, den = out[2].split("/")
        return out[0], out[1], f"{round(int(num) / int(den), 3):g}"
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def set_settings(target, pairs, label):
    for key, value in pairs:
        if not target.SetSetting(key, value):
            print(f"  warning: {label} setting {key}={value} was rejected (now {target.GetSetting(key)!r})", file=sys.stderr)


def pick_codec(project, fmt):
    codecs = project.GetRenderCodecs(fmt) or {}
    hevc = [(desc, name) for desc, name in codecs.items() if "265" in desc or "265" in name or "HEVC" in desc.upper()]
    if not hevc:
        fail(f"no H.265 codec offered for {fmt}: {codecs}")
    hevc.sort(key=lambda c: ("apple" not in c[0].lower(), c[0]))
    return hevc[0][1]


def main():
    parser = argparse.ArgumentParser(description="Batch D-Log M to HLG (plus optional beauty PowerGrade) through DaVinci Resolve Studio")
    parser.add_argument("inputs", nargs="+", help="video files or folders")
    parser.add_argument("-o", "--output", help="output folder (default: <input folder>/HDR-Resolve)")
    parser.add_argument("--lut", default=DEFAULT_LUT, help="D-Log M to HLG .cube applied on node 1")
    parser.add_argument("--no-lut", action="store_true", help="do not set a LUT (when the PowerGrade already contains it)")
    parser.add_argument("--drx", help="PowerGrade still (.drx) applied to every clip before the LUT, e.g. node 2 with ResolveFX Beauty")
    parser.add_argument("--magic-mask", action="store_true", help="track Magic Mask on each clip after applying the PowerGrade")
    parser.add_argument("--preset", help="Resolve render preset to load instead of the built-in H.265 settings")
    parser.add_argument("--bitrate", type=int, default=80, help="H.265 bitrate in Mbit/s (default 80)")
    parser.add_argument("--keep-project", action="store_true", help="keep the temporary Resolve project")
    parser.add_argument("--timeout", type=int, default=120, help="seconds to wait for Resolve to start")
    args = parser.parse_args()

    files = collect(args.inputs)
    if not files:
        fail("no videos found")
    lut = None if args.no_lut else install_lut(os.path.abspath(args.lut))
    drx = os.path.abspath(args.drx) if args.drx else None

    resolve = connect(args.timeout)
    print(f"connected to {resolve.GetProductName()} {resolve.GetVersionString()}")
    manager = resolve.GetProjectManager()
    name = time.strftime("osmohdr-%Y%m%d-%H%M%S")
    project = manager.CreateProject(name)
    if not project:
        fail(f"cannot create project {name}")
    try:
        process(args, files, lut, drx, project)
    finally:
        if args.keep_project:
            manager.SaveProject()
        else:
            manager.CloseProject(project)
            manager.DeleteProject(name)


def process(args, files, lut, drx, project):
    media_pool = project.GetMediaPool()
    probed = probe_format(files[0])
    if probed:
        set_settings(project, [("timelineResolutionWidth", probed[0]), ("timelineResolutionHeight", probed[1]), ("timelineFrameRate", probed[2])], "project")
    clips = media_pool.ImportMedia(files) or []
    if not clips:
        fail("Resolve imported nothing")
    first = clips[0]
    width, height = (first.GetClipProperty("Resolution") or "3840x2160").split("x")
    fps = f"{round(float(first.GetClipProperty('FPS')), 3):g}"
    set_settings(project, [
        ("timelineResolutionWidth", width),
        ("timelineResolutionHeight", height),
        ("timelineFrameRate", fps),
        ("colorScienceMode", "davinciYRGB"),
        ("colorSpaceTimeline", "Rec.2100 HLG"),
        ("colorSpaceOutput", "Rec.2100 HLG"),
        ("videoDataLevels", "Video"),
    ], "project")
    if lut:
        project.RefreshLUTList()

    if args.preset:
        if not project.LoadRenderPreset(args.preset):
            fail(f"render preset {args.preset!r} not found: {[p.get('PresetName', p) for p in project.GetRenderPresetList()]}")
    else:
        project.LoadRenderPreset("H.265 Master")
        codec = pick_codec(project, "mov")
        if not project.SetCurrentRenderFormatAndCodec("mov", codec):
            fail(f"cannot select mov/{codec}")
    project.SetCurrentRenderMode(1)

    jobs = []
    for clip in clips:
        path = clip.GetClipProperty("File Path")
        base = os.path.splitext(os.path.basename(path))[0]
        if f"{round(float(clip.GetClipProperty('FPS')), 3):g}" != fps:
            print(f"  skip {base}: {clip.GetClipProperty('FPS')} fps differs from {fps} fps in this batch", file=sys.stderr)
            continue
        timeline = media_pool.CreateTimelineFromClips(base, [{"mediaPoolItem": clip}]) or media_pool.CreateTimelineFromClips(base, [clip])
        if not timeline:
            print(f"  skip {base}: cannot create timeline", file=sys.stderr)
            continue
        project.SetCurrentTimeline(timeline)
        items = timeline.GetItemListInTrack("video", 1) or []
        if not items:
            print(f"  skip {base}: empty timeline", file=sys.stderr)
            continue
        item = items[0]
        graph = item.GetNodeGraph()
        if drx and not graph.ApplyGradeFromDRX(drx, 0):
            print(f"  warning: PowerGrade not applied to {base}", file=sys.stderr)
        if lut and not graph.SetLUT(1, lut):
            print(f"  warning: LUT {lut} not applied to {base}", file=sys.stderr)
        if args.magic_mask and not item.CreateMagicMask("BI"):
            print(f"  warning: Magic Mask tracking failed on {base}", file=sys.stderr)
        out_dir = os.path.abspath(args.output) if args.output else os.path.join(os.path.dirname(path), "HDR-Resolve")
        os.makedirs(out_dir, exist_ok=True)
        settings = {
            "SelectAllFrames": True,
            "TargetDir": out_dir,
            "CustomName": base + "_HDR",
            "ExportVideo": True,
            "ExportAudio": True,
        }
        if not args.preset:
            settings.update({
                "EncodingProfile": "Main10",
                "VideoQuality": args.bitrate * 1000,
            })
        if not project.SetRenderSettings(settings):
            print(f"  warning: some render settings were rejected for {base}", file=sys.stderr)
        job = project.AddRenderJob()
        if job:
            jobs.append((job, base, os.path.join(out_dir, base + "_HDR.mov")))
            print(f"  queued {base}")
        else:
            print(f"  skip {base}: AddRenderJob failed", file=sys.stderr)

    if not jobs:
        fail("nothing to render")
    started = time.time()
    if not project.StartRendering([j for j, _, _ in jobs], False):
        print("  warning: StartRendering returned False", file=sys.stderr)
    while project.IsRenderingInProgress():
        done = [project.GetRenderJobStatus(j).get("CompletionPercentage", 0) for j, _, _ in jobs]
        print(f"\r  rendering {sum(done) / len(done):5.1f}%  {time.time() - started:6.0f}s", end="", flush=True)
        time.sleep(2)
    print()
    for job, base, out in jobs:
        status = project.GetRenderJobStatus(job)
        print(f"  {base}: {status.get('JobStatus')} -> {out}")


if __name__ == "__main__":
    main()
