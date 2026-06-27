# MiSTer CD-i VCD Factory

Convert video files into **Philips CD-i compatible VCD disc images** (.bin/.cue/.chd) for use with the [MiSTer FPGA CD-i core](https://github.com/Slamy/MiSTer_cdi).

Forked from [mrchrisster/mister_cdi_vcd_creator](https://github.com/mrchrisster/mister_cdi_vcd_creator).

---

## Features

- **Two quality modes** — Ultra (best quality, slow) or Fast (good quality, much faster)
- **Auto disc splitting** — Films longer than 96 minutes are automatically split into evenly-timed discs to stay within VCD's sector limit
- **PAL / NTSC auto-detection** — Frame rate is detected and the correct standard is applied automatically
- **4:3 auto-crop** — Widescreen content is center-cropped to 4:3; fullscreen content is passed through unchanged
- **Full-featured CD-i bridge** — Uses CDI_VCD.APP (icdia.co.uk v4.11) by default, giving you working player controls and timecode display
- **CHD output** — Disc images are automatically compressed to .chd for use with MiSTer
- **Batch processing** — Drop multiple files in the input folder and they all encode in sequence
- **macOS and Linux** — Dependencies install automatically on Homebrew (macOS) and Debian/Ubuntu

## Requirements

- **Linux (Debian/Ubuntu):** `ffmpeg`, `mjpegtools`, `vcdimager`, `mame-tools`, `bc`
- **macOS:** Homebrew — `ffmpeg`, `mjpegtools`, `vcdimager`, `rom-tools`, `bc`

Missing tools are installed automatically on first run.

## Setup

```bash
mkdir -p ~/mister_cdi_vcd_creator && cd ~/mister_cdi_vcd_creator
curl -kLO https://raw.githubusercontent.com/kadafi916/mister_cdi_vcd_creator/main/batch_vcd_creator.sh
chmod +x batch_vcd_creator.sh
```

## Usage

1. Place your video file(s) in the `input/` folder
2. Run the script:

```bash
./batch_vcd_creator.sh               # ultra quality (default)
./batch_vcd_creator.sh --fast        # faster encode, still good quality
```

3. Finished `.chd` files appear in `output/`
4. Copy them to your MiSTer's CD-i games folder

## Flags

| Flag | Description |
|------|-------------|
| *(none)* | Ultra quality — advanced deinterlacing, noise reduction, Lanczos scaling, exhaustive motion search |
| `--fast` | Fast mode — Lanczos scaling, lighter motion search. Much faster, still very watchable |
| `--fastaudio` | Skip loudnorm audio normalization (faster, slightly less consistent volume) |
| `--fast --fastaudio` | Fastest possible encode |
| `--mistrvcd` | Use the minimal MISTRVCD.APP bridge instead of CDI_VCD.APP (no player controls) |
| `--force-mono` | Force mono audio output at 128 kbps |
| `--auto-mono` | Detect and downmix to mono if both stereo channels are identical |
| `--lax` | Also produce a second disc image without strict sector alignment (for compatibility testing) |

## Disc Splitting

Videos longer than 96 minutes are automatically split into multiple evenly-timed discs. A 2-hour film becomes two ~60-minute discs; output files are named `_disc1`, `_disc2`, etc.

The 96-minute limit exists because vcdxbuild has a hardcoded sector ceiling of ~449,850 sectors (75 sectors/sec × ~100 min). The 96-minute cutoff gives a small safety margin.

## CD-i Bridge

The script downloads **CDI_VCD.APP v4.11** from [icdia.co.uk](http://www.icdia.co.uk) — a full-featured VCD player for CD-i with on-screen controls, chapter navigation, and timecode display. It auto-plays on disc insert.

Use `--mistrvcd` to substitute the minimal MISTRVCD.APP for a plain autoplay-only experience.

## Output Files

For each input file the script produces:

| File | Description |
|------|-------------|
| `output/<name>.bin` | Raw CD image |
| `output/<name>.cue` | Cue sheet |
| `output/<name>.chd` | Compressed image for MiSTer |
| `output/<name>.log` | Full encode log |

Intermediate files (`temp_video.m1v`, `temp_audio.mp2`, `compliant.mpg`) are preserved on failure so you can debug without re-encoding from scratch.

## Credits

- Original script by [mrchrisster](https://github.com/mrchrisster/mister_cdi_vcd_creator)
- MiSTer CD-i core by [Slamy](https://github.com/Slamy) — see also his [MPEG1 Handbook](https://github.com/Slamy/MPEG1_Handbook)
- CDI_VCD.APP by [icdia.co.uk](http://www.icdia.co.uk)
