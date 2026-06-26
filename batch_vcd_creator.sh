#!/bin/bash

# ==============================================================================
#  CD-i VIDEO CD FACTORY (v19 - DUAL MODE EDITION)
#  - DEFAULT: Ultra quality mode (slow but best quality)
#  - OPTION: Fast mode with --fast flag (good quality, much faster)
#  - Audio is always fully processed (soxr + loudnorm) regardless of video mode
#  - Use --fastaudio to skip audio normalization (faster, no loudnorm)
#  - Use --mister to bypass vcdxbuild's ~99.8-min disc size limit (MiSTer-only output)
#    Builds the BIN/CUE manually from raw CD sectors; requires python3.
#    Long films fit on a single CHD; real CD-i hardware cannot use the result.
#  - Usage: ./script.sh                      (ultra quality - default)
#           ./script.sh --fast               (fast video, full audio)
#           ./script.sh --fastaudio          (ultra video, minimal audio)
#           ./script.sh --fast --fastaudio   (fast video, minimal audio)
#           ./script.sh --mister             (single disc, no size limit, MiSTer only)
#           ./script.sh --mistrvcd           (use minimal MISTRVCD.APP instead of CDI_VCD.APP)
# ==============================================================================

# --- CONFIGURATION ---
INPUT_DIR="./input"
OUTPUT_DIR="./output"
CDI_FIX_DIR="./cdi_fix"
MISTR_APP="./MISTRVCD.APP"  # Path to MISTRVCD.APP file
MAX_DISC_SECONDS=5760        # 96 min per disc; vcdxbuild hard limit is ~99.8 min (449850 sectors / 75 minus overhead)

# --- QUALITY MODE SELECTION ---
QUALITY_MODE="ultra"  # Default to ultra
LAX_MODE=false        # Default: don't create lax version
AUDIO_MODE="stereo"   # Default: stereo at 224 kbps
FAST_AUDIO=false      # Default: full audio processing (soxr + loudnorm); --fastaudio skips filters
USE_CDIVCD=true        # Default: use CDI_VCD.APP (icdia.co.uk); --mistrvcd to use minimal MISTRVCD.APP
MISTER_MODE=false      # Default: standard vcdxbuild path; --mister bypasses disc size limit

# Parse command line arguments
for arg in "$@"; do
    if [[ "$arg" == "--fast" ]]; then
        QUALITY_MODE="fast"
    elif [[ "$arg" == "--fastaudio" ]]; then
        FAST_AUDIO=true
    elif [[ "$arg" == "--lax" ]]; then
        LAX_MODE=true
    elif [[ "$arg" == "--force-mono" ]]; then
        AUDIO_MODE="force-mono"
    elif [[ "$arg" == "--auto-mono" ]]; then
        AUDIO_MODE="auto-mono"
    elif [[ "$arg" == "--cdivcd" ]]; then
        USE_CDIVCD=true   # already the default; kept for backwards compatibility
    elif [[ "$arg" == "--mistrvcd" ]]; then
        USE_CDIVCD=false
    elif [[ "$arg" == "--mister" ]]; then
        MISTER_MODE=true
    fi
done

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- CROSS-PLATFORM HELPERS ---
# macOS (BSD) sed requires `sed -i ''`, GNU sed uses `sed -i`
sed_i() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# macOS (BSD) du and GNU du have different output formats
# This returns a human-readable size string portably
portable_du() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # BSD stat -f%z gives bytes; we convert to human-readable
        local bytes
        bytes=$(stat -f%z "$1" 2>/dev/null || echo 0)
    else
        local bytes
        bytes=$(stat -c%s "$1" 2>/dev/null || echo 0)
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fG\n", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fM\n", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fK\n", b/1024}'
    else
        echo "${bytes}B"
    fi
}

# ==============================================================================
#  1. SYSTEM CHECK
# ==============================================================================
install_deps() {
    echo -e "${BLUE}🔍 Checking system dependencies...${NC}"
    local MISSING_TOOLS=0
    
    # 1. Check for Standard Tools
    for tool in ffmpeg ffprobe mpeg2enc mplex vcdxbuild curl unzip bc; do
        if ! command -v $tool &> /dev/null; then 
            MISSING_TOOLS=1
            echo -e "${RED}❌ Missing tool: $tool${NC}"
        fi
    done

    # 2. Check for CHDMAN
    if ! command -v chdman &> /dev/null; then
        MISSING_TOOLS=1
        echo -e "${RED}❌ Missing tool: chdman${NC}"
    fi

    # 3. python3 required for --mister mode
    if [ "$MISTER_MODE" == "true" ] && ! command -v python3 &>/dev/null; then
        MISSING_TOOLS=1
        echo -e "${RED}❌ Missing tool: python3 (required for --mister mode)${NC}"
    fi

    if [ $MISSING_TOOLS -eq 0 ]; then
        echo -e "${GREEN}✅ All tools are installed.${NC}"
        return
    fi

    # 3. Auto-Install Logic
    echo -e "${YELLOW}⚠️  Missing tools detected. Attempting installation...${NC}"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if ! command -v brew &> /dev/null; then echo -e "${RED}❌ Install Homebrew first.${NC}"; exit 1; fi
        brew install ffmpeg mjpegtools vcdimager rom-tools bc
    elif [ -f /etc/debian_version ]; then
        sudo apt-get update
        sudo apt-get install -y ffmpeg mjpegtools vcdimager curl unzip mame-tools bc python3
    else
        echo -e "${RED}❌ Unsupported OS. Please install dependencies manually.${NC}"
        exit 1
    fi
}

# ==============================================================================
#  2. BRIDGE & CONFIG SETUP
# ==============================================================================
setup_bridge() {
    mkdir -p "$CDI_FIX_DIR"

    # Download if missing
    if [ ! -f "$CDI_FIX_DIR/CDI_VCD.APP" ]; then
        curl -L -o "$CDI_FIX_DIR/bridge.zip" http://www.icdia.co.uk/sw_app/vcd_on_cdi_411.zip
        unzip -o -q "$CDI_FIX_DIR/bridge.zip" -d "$CDI_FIX_DIR"
        rm "$CDI_FIX_DIR/bridge.zip"
        
        # FIX: macOS compatible uppercase conversion using 'tr'
        for f in "$CDI_FIX_DIR"/*; do
            DIRNAME=$(dirname "$f")
            BASENAME=$(basename "$f")
            UPPER_NAME=$(echo "$BASENAME" | tr '[:lower:]' '[:upper:]')
            if [ "$BASENAME" != "$UPPER_NAME" ]; then
                mv "$f" "$DIRNAME/$UPPER_NAME" 2>/dev/null
            fi
        done
        
        # Ensure main app is definitely present under the expected name
        mv "$CDI_FIX_DIR/CDI_VCD.APP" "$CDI_FIX_DIR/CDI_VCD.APP" 2>/dev/null
    fi

    # Config Generation
    if [ ! -f "$CDI_FIX_DIR/CDI_VCD.CFG" ]; then
        cat > "$CDI_FIX_DIR/CDI_VCD.CFG" <<EOF
CONTROLS=ALL
CURCOL=YELLOW
PSDCURCOL=RED
PSDCURSHAPE=ARROW
CENTRTRACK=2
AUTOPLAY=AUTO_ON
DUALCHAN=DUAL_ON
TIMECODE_X=64
TIMECODE_Y=100
LOTID_X=64
LOTID_Y=64
ALBUM=STANDARD
EOF
    fi
}

# ==============================================================================
#  GENERATE VCD XML
# ==============================================================================
generate_vcd_xml() {
    local OUTPUT_FILE="$1"
    local VOLUME_ID_VALUE="$2"
    local USE_CDI="$3"
    local CDI_DIR="$4"
    local MISTR_PATH="$5"
    local MISTR_NAME_UPPER="$6"
    
    if [ "$USE_CDI" = true ]; then
        # CDI_VCD.APP format (4 files)
        cat > "$OUTPUT_FILE" <<'XMLEOF'
<?xml version="1.0"?>
<!DOCTYPE videocd PUBLIC "-//GNU//DTD VideoCD//EN" "http://www.gnu.org/software/vcdimager/videocd.dtd">
<videocd xmlns="http://www.gnu.org/software/vcdimager/1.0/" class="vcd" version="2.0">
  <info><album-id/><volume-count>1</volume-count><volume-number>1</volume-number><restriction>0</restriction></info>
  <pvd>
    <volume-id>PLACEHOLDER_NAME</volume-id>
    <system-id>CD-RTOS CD-BRIDGE</system-id>
    <application-id>CDI/CDI_VCD.APP;1</application-id>
  </pvd>
  <filesystem>
    <folder>
      <name>SEGMENT</name>
    </folder>
    <folder>
      <name>CDI</name>
      <file src="PLACEHOLDER_CDI/CDI_IMAG.RTF" format="mixed">
        <name>CDI_IMAG.RTF</name>
      </file>
      <file src="PLACEHOLDER_CDI/CDI_TEXT.FNT">
        <name>CDI_TEXT.FNT</name>
      </file>
      <file src="PLACEHOLDER_CDI/CDI_VCD.APP">
        <name>CDI_VCD.APP</name>
      </file>
      <file src="PLACEHOLDER_CDI/CDI_VCD.CFG">
        <name>CDI_VCD.CFG</name>
      </file>
    </folder>
  </filesystem>
  <sequence-items>
    <sequence-item src="compliant.mpg" id="sequence-00">
      <default-entry id="entry-000"/>
    </sequence-item>
  </sequence-items>
</videocd>
XMLEOF
        sed_i "s|PLACEHOLDER_NAME|${VOLUME_ID_VALUE}|g" "$OUTPUT_FILE"
        sed_i "s|PLACEHOLDER_CDI|${CDI_DIR}|g" "$OUTPUT_FILE"
    else
        # MISTRVCD.APP format (single file)
        cat > "$OUTPUT_FILE" <<'XMLEOF'
<?xml version="1.0"?>
<!DOCTYPE videocd PUBLIC "-//GNU//DTD VideoCD//EN" "http://www.gnu.org/software/vcdimager/videocd.dtd">
<videocd xmlns="http://www.gnu.org/software/vcdimager/1.0/" class="vcd" version="2.0">
  <info><album-id/><volume-count>1</volume-count><volume-number>1</volume-number><restriction>0</restriction></info>
  <pvd>
    <volume-id>PLACEHOLDER_NAME</volume-id>
    <system-id>CD-RTOS CD-BRIDGE</system-id>
    <application-id>CDI/PLACEHOLDER_MISTR_NAME;1</application-id>
  </pvd>
  <filesystem>
    <folder>
      <name>SEGMENT</name>
    </folder>
    <folder>
      <name>CDI</name>
      <file src="PLACEHOLDER_MISTR">
        <name>PLACEHOLDER_MISTR_NAME</name>
      </file>
    </folder>
  </filesystem>
  <sequence-items>
    <sequence-item src="compliant.mpg" id="sequence-00">
      <default-entry id="entry-000"/>
    </sequence-item>
  </sequence-items>
</videocd>
XMLEOF
        sed_i "s|PLACEHOLDER_NAME|${VOLUME_ID_VALUE}|g" "$OUTPUT_FILE"
        sed_i "s|PLACEHOLDER_MISTR_NAME|${MISTR_NAME_UPPER}|g" "$OUTPUT_FILE"
        sed_i "s|PLACEHOLDER_MISTR|${MISTR_PATH}|g" "$OUTPUT_FILE"
    fi
}

# ==============================================================================
#  BUILD IMAGE - MISTER MODE
#  Bypasses vcdxbuild's hardcoded ~449850-sector limit by building the BIN/CUE
#  manually from raw Mode 2 CD sectors. Output is NOT burnable to real media.
#  Reads: compliant.mpg (current dir)
#  Writes: videocd.bin, videocd.cue (current dir) — same as vcdxbuild would
# ==============================================================================
build_image_mister() {
    local LOG_FILE="$1"
    local VOLUME_LABEL="$2"

    echo -e "\n--- IMAGE BUILD LOG (MISTER MODE - NO SIZE LIMIT) ---" >> "$LOG_FILE"

    # Resolve absolute paths — vcdxbuild for the track-1 template will run from a tmpdir
    local ABS_MISTR_APP ABS_CDI_DIR MISTR_UPPER TMPDIR
    ABS_MISTR_APP=$(realpath "$MISTR_APP")
    ABS_CDI_DIR=$(realpath "$CDI_FIX_DIR")
    MISTR_UPPER=$(basename "$ABS_MISTR_APP" | tr '[:lower:]' '[:upper:]')
    TMPDIR=$(mktemp -d)

    # --- Step 1: Generate a tiny dummy VCD so vcdxbuild builds us a valid track 1 ---
    ffmpeg -f lavfi -i "color=black:s=352x240:r=30000/1001" \
        -t 1 -pix_fmt yuv420p -f yuv4mpegpipe - 2>/dev/null \
        | mpeg2enc -v 0 -o "$TMPDIR/dummy.m1v" -f 1 -n n -a 2 -b 1150 -q 9 2>/dev/null
    ffmpeg -f lavfi -i "anullsrc=r=44100:cl=stereo" \
        -t 1 -b:a 224k -f mp2 -y "$TMPDIR/dummy.mp2" 2>/dev/null
    mplex -f 1 -b 46 -o "$TMPDIR/compliant.mpg" \
        "$TMPDIR/dummy.mp2" "$TMPDIR/dummy.m1v" 2>/dev/null

    # Generate XML with absolute CDI paths; compliant.mpg is relative (found in TMPDIR)
    generate_vcd_xml "$TMPDIR/videocd.xml" "$VOLUME_LABEL" "$USE_CDIVCD" \
        "$ABS_CDI_DIR" "$ABS_MISTR_APP" "$MISTR_UPPER"

    # Run vcdxbuild from TMPDIR so relative "compliant.mpg" resolves correctly
    pushd "$TMPDIR" > /dev/null
    vcdxbuild videocd.xml >> "$LOG_FILE" 2>&1
    popd > /dev/null

    if [ ! -f "$TMPDIR/videocd.bin" ]; then
        echo -e "${RED}❌ MiSTer mode: failed to generate track 1 template.${NC}"
        rm -rf "$TMPDIR"
        return 1
    fi

    # --- Step 2: Extract track 1 (300 sectors) + pregap (150 sectors) = 450 × 2352 bytes ---
    dd if="$TMPDIR/videocd.bin" bs=$((450 * 2352)) count=1 \
        of="$TMPDIR/track_header.bin" 2>/dev/null

    # Patch volume label in ISO 9660 PVD
    # Sector 16 raw offset: 16 × 2352 = 37632; + 24 bytes sector overhead; + 40 bytes PVD field = 37696
    printf '%-32s' "${VOLUME_LABEL:0:32}" | \
        dd of="$TMPDIR/track_header.bin" bs=1 seek=37696 conv=notrunc 2>/dev/null

    # --- Step 3: Pack MPEG stream into raw Mode 2 Form 2 CD sectors (python3) ---
    # Each VCD MPEG pack is exactly 2324 bytes; wrap with 12-byte sync + 4-byte header +
    # 8-byte subheader + 4-byte EDC = 2352-byte raw sector. No size limit enforced.
    python3 - compliant.mpg "$TMPDIR/track2.bin" << 'PYEOF'
import sys

SYNC = b'\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00'
PACK_SIZE = 2324
ABS_START = 450  # track1 (300 sectors) + pregap (150 sectors)
SUBHDR = b'\x01\x01\x08\x00\x01\x01\x08\x00'

def bcd(v): return ((v // 10) << 4) | (v % 10)

def make_sector(data, n):
    f, s, m = n % 75, (n // 75) % 60, n // 75 // 60
    return SYNC + bytes([bcd(m), bcd(s), bcd(f), 2]) + SUBHDR + data + b'\x00' * 4

with open(sys.argv[1], 'rb') as fi, open(sys.argv[2], 'wb') as fo:
    n = 0
    while True:
        d = fi.read(PACK_SIZE)
        if not d:
            break
        if len(d) < PACK_SIZE:
            d += b'\x00' * (PACK_SIZE - len(d))
        fo.write(make_sector(d, ABS_START + n))
        n += 1
PYEOF

    if [ ! -s "$TMPDIR/track2.bin" ]; then
        echo -e "${RED}❌ MiSTer mode: failed to pack MPEG stream into CD sectors.${NC}"
        rm -rf "$TMPDIR"
        return 1
    fi

    # --- Step 4: Assemble final BIN + CUE (same filenames vcdxbuild would produce) ---
    cat "$TMPDIR/track_header.bin" "$TMPDIR/track2.bin" > videocd.bin

    cat > videocd.cue << 'CUEEOF'
FILE "videocd.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
  TRACK 02 MODE2/2352
    INDEX 00 00:04:00
    INDEX 01 00:06:00
CUEEOF

    rm -rf "$TMPDIR"
    echo "MiSTer mode: disc image assembled without sector count limit" >> "$LOG_FILE"
}

# ==============================================================================
#  3. PROCESSING PIPELINE
# ==============================================================================
process_video() {
    local FILE="$1"
    local SEG_START="${2:-0}"       # start time in seconds (default: 0 = whole file)
    local SEG_DURATION="${3:-}"     # max duration for this segment (default: entire file)
    local DISC_NUM="${4:-}"         # disc number suffix (default: none = single disc)

    local FILENAME=$(basename -- "$FILE")
    local NAME="${FILENAME%.*}"
    local CLEAN_NAME=$(echo "$NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')

    local DISC_SUFFIX=""
    [ -n "$DISC_NUM" ] && DISC_SUFFIX="_disc${DISC_NUM}"

    # Seek/duration flags: -ss before -i for fast input seek; -t limits encode length
    local FFMPEG_SEEK=""
    local FFMPEG_DURATION=""
    if [ -n "$SEG_DURATION" ]; then
        FFMPEG_SEEK="-ss $SEG_START"
        FFMPEG_DURATION="-t $SEG_DURATION"
    fi

    local LOG_FILE="$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.log"

    # Extract MISTR basename for XML generation
    local MISTR_BASENAME=$(basename "$MISTR_APP")
    local MISTR_BASENAME_UPPER=$(echo "$MISTR_BASENAME" | tr '[a-z]' '[A-Z]')
    
    echo -e "\n${BLUE}🎬 Processing: $FILENAME${NC}"
    
    if [ "$QUALITY_MODE" == "ultra" ]; then
        echo -e "${YELLOW}⏱️  Mode: ULTRA QUALITY (this will take longer)${NC}"
    else
        echo -e "${GREEN}⚡ Mode: FAST (good quality, faster encoding)${NC}"
    fi
    
    echo "----------------------------------------------------------------" > "$LOG_FILE"
    echo "CD-i VCD Factory Log - $(date)" >> "$LOG_FILE"
    echo "Quality Mode: $QUALITY_MODE" >> "$LOG_FILE"
    echo "File: $FILENAME" >> "$LOG_FILE"
    echo "----------------------------------------------------------------" >> "$LOG_FILE"

    # 3.1 DETECT FRAMERATE & SET STANDARD
    RAW_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$FILE")
    
    if [ -z "$RAW_FPS" ]; then
        echo -e "${RED}❌ Error: Could not detect framerate.${NC}"
        return
    fi

    FPS_INT=$(echo $RAW_FPS | awk -F/ '{ if ($2 == 0) print 0; else print int($1/$2 + 0.5) }')

    # Detect interlaced content
    INTERLACED=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of default=noprint_wrappers=1:nokey=1 "$FILE")
    
    # === PAL VS NTSC LOGIC ===
    if [ "$FPS_INT" -eq 25 ] || [ "$FPS_INT" -eq 50 ]; then
        MODE_MSG="PAL (25 fps)"
        FFMPEG_RATE="-r 25"
        TV_STD_FLAG="-n p"
        SCALE_RES="352:288"
    elif [ "$FPS_INT" -lt 26 ]; then
        MODE_MSG="NTSC FILM (23.976 fps)"
        FFMPEG_RATE="-r 24000/1001"
        TV_STD_FLAG="-n n"
        SCALE_RES="352:240"
    else
        MODE_MSG="NTSC VIDEO (29.97 fps)"
        FFMPEG_RATE="-r 30000/1001"
        TV_STD_FLAG="-n n"
        SCALE_RES="352:240"
    fi

    echo -e "   ${CYAN}📊 Detected $FPS_INT fps. Mode: $MODE_MSG${NC}"
    echo "Detection: $FPS_INT fps -> Mode: $MODE_MSG | Res: $SCALE_RES" >> "$LOG_FILE"
    echo "Interlacing: $INTERLACED" >> "$LOG_FILE"

    # 3.2 BUILD FILTER CHAIN AND MPEG2ENC SETTINGS BASED ON QUALITY MODE
    if [ "$QUALITY_MODE" == "ultra" ]; then
        # ULTRA QUALITY MODE
        echo -e "   ${YELLOW}⚡ Encoding Video Stream (ULTRA QUALITY)...${NC}"
        echo -e "\n--- VIDEO ENCODING LOG ---" >> "$LOG_FILE"
        echo "ULTRA QUALITY OPTIMIZATIONS:" >> "$LOG_FILE"
        echo "  ✓ Advanced deinterlacing (yadif=1:0:1)" >> "$LOG_FILE"
        echo "  ✓ Temporal noise reduction (hqdn3d)" >> "$LOG_FILE"
        echo "  ✓ Lanczos scaling (sharpest)" >> "$LOG_FILE"
        echo "  ✓ Contrast/saturation enhancement" >> "$LOG_FILE"
        echo "  ✓ Adaptive sharpening (unsharp filter)" >> "$LOG_FILE"
        echo "  ✓ GOP size: 12 frames" >> "$LOG_FILE"
        echo "  ✓ Quality preset: 9 (exhaustive search)" >> "$LOG_FILE"
        echo "  ✓ 4:2:0 chroma, 10-bit DC, Closed GOP" >> "$LOG_FILE"
        echo "----------------------------------------------------------------" >> "$LOG_FILE"
        
        FILTER_CHAIN="yadif=1:-1:1,hqdn3d=1.5:1.5:6:6,crop='min(iw,ih*4/3)':'min(ih,iw*3/4)',scale=$SCALE_RES:flags=lanczos+accurate_rnd,eq=contrast=1.05:saturation=1.15:gamma=1.0,unsharp=5:5:0.5:5:5:0.0"
        
        # VBV buffer: Using -V 46 instead of 230 for better hardware compatibility
        # Smaller buffer = more conservative = less chance of decoder underruns
        MPEG2ENC_OPTS="-v 0 -o temp_video.m1v -f 1 $TV_STD_FLAG -a 2 -K tmpgenc -g 12 -G 12 -q 9 -4 2 -2 1 -b 1150 -V 46  -D 10 -c"
        
    else
        # FAST MODE (actually fast!)
        echo -e "   ${YELLOW}⚡ Encoding Video Stream (FAST MODE)...${NC}"
        echo -e "\n--- VIDEO ENCODING LOG ---" >> "$LOG_FILE"
        echo "FAST MODE OPTIMIZATIONS:" >> "$LOG_FILE"
        echo "  ✓ Lanczos scaling" >> "$LOG_FILE"
        echo "  ✓ Enhanced color/contrast" >> "$LOG_FILE"
        echo "  ✓ GOP size: 15 frames" >> "$LOG_FILE"
        echo "  ✓ Quality preset: 6 (good speed/quality balance)" >> "$LOG_FILE"
        echo "  ✓ 4:2:0 chroma, 10-bit DC" >> "$LOG_FILE"
        echo "----------------------------------------------------------------" >> "$LOG_FILE"
        
        FILTER_CHAIN="crop='min(iw,ih*4/3)':'min(ih,iw*3/4)',scale=$SCALE_RES:flags=lanczos,eq=contrast=1.05:saturation=1.1"
        
        # Fast mode: -q 6 instead of -q 9, and -4 2 -2 3 for faster motion search
        MPEG2ENC_OPTS="-v 0 -o temp_video.m1v -f 1 $TV_STD_FLAG -a 2 -K tmpgenc -g 15 -G 15 -q 6 -4 2 -2 3 -b 1150 -V 46 -D 10"
    fi
    
    # ENCODE VIDEO (multi-threaded ffmpeg for both modes)
    ffmpeg -threads 0 -v info $FFMPEG_SEEK -i "$FILE" \
        -vf "$FILTER_CHAIN" \
        $FFMPEG_DURATION \
        $FFMPEG_RATE -pix_fmt yuv420p -f yuv4mpegpipe - 2>> "$LOG_FILE" \
        | mpeg2enc $MPEG2ENC_OPTS 2>> "$LOG_FILE"

    if [ ! -s "temp_video.m1v" ]; then 
        echo -e "${RED}❌ Encoding failed. Check $LOG_FILE.${NC}"
        return
    fi
    
    VIDEO_SIZE=$(portable_du "temp_video.m1v")
    echo -e "   ${GREEN}✅ Video encoded: $VIDEO_SIZE${NC}"

    # 3.3 ENCODE AUDIO (with mono detection/forcing options)
    echo -e "   ${YELLOW}⚡ Encoding Audio Stream...${NC}"
    
    # Determine audio settings based on mode
    AUDIO_CHANNELS=2
    AUDIO_BITRATE="224k"
    
    if [ "$AUDIO_MODE" == "auto-mono" ]; then
        # Auto-detect if stereo channels are identical
        echo "   Analyzing audio channels..." >> "$LOG_FILE"
        CHANNEL_DIFF=$(ffmpeg -i "$FILE" -filter_complex "[0:a]channelsplit=channel_layout=stereo[L][R];[L][R]join=inputs=2:channel_layout=stereo[out]" -map "[out]" -f null - 2>&1 | grep -o "stddev:[0-9.]*" | head -1 | cut -d: -f2 || echo "1.0")
        
        # If channels are nearly identical (stddev < 0.001), treat as mono
        if (( $(echo "$CHANNEL_DIFF < 0.001" | bc -l) )); then
            echo "   Detected identical channels - encoding as mono" >> "$LOG_FILE"
            AUDIO_CHANNELS=1
            AUDIO_BITRATE="128k"
            echo -e "   ${CYAN}📊 Auto-detected: Channels identical, using mono (128 kbps)${NC}"
        else
            echo "   Detected true stereo - encoding as stereo" >> "$LOG_FILE"
            echo -e "   ${CYAN}📊 Auto-detected: True stereo content (224 kbps)${NC}"
        fi
    elif [ "$AUDIO_MODE" == "force-mono" ]; then
        AUDIO_CHANNELS=1
        AUDIO_BITRATE="128k"
        echo "   Forcing mono output" >> "$LOG_FILE"
        echo -e "   ${CYAN}📊 Force-mono: Downmixing to mono (128 kbps)${NC}"
    else
        echo "   Using stereo output (default)" >> "$LOG_FILE"
    fi
    
    # Build audio encoding command based on audio mode (independent of video quality)
    if [ "$FAST_AUDIO" == "true" ]; then
        # --fastaudio: minimal encoding, no filters
        ffmpeg -v info $FFMPEG_SEEK -i "$FILE" \
            $FFMPEG_DURATION \
            -ar 44100 -ac $AUDIO_CHANNELS -b:a $AUDIO_BITRATE \
            -f mp2 -y "temp_audio.mp2" >> "$LOG_FILE" 2>&1
    else
        # Default (all modes): full processing with loudnorm
        # Detect if soxr resampler is available (not included in default macOS Homebrew ffmpeg)
        if ffmpeg -hide_banner -filters 2>/dev/null | grep -q soxr; then
            AUDIO_RESAMPLE_FILTER="aresample=resampler=soxr,"
        else
            AUDIO_RESAMPLE_FILTER=""
        fi
        ffmpeg -v info $FFMPEG_SEEK -i "$FILE" \
            $FFMPEG_DURATION \
            -af "${AUDIO_RESAMPLE_FILTER}loudnorm=I=-16:TP=-1.5:LRA=11" \
            -ar 44100 -ac $AUDIO_CHANNELS -b:a $AUDIO_BITRATE -compression_level 0 \
            -f mp2 -y "temp_audio.mp2" >> "$LOG_FILE" 2>&1
    fi
    
    AUDIO_SIZE=$(portable_du "temp_audio.mp2")
    if [ "$AUDIO_CHANNELS" -eq 1 ]; then
        echo -e "   ${GREEN}✅ Audio encoded: $AUDIO_SIZE (mono at $AUDIO_BITRATE)${NC}"
    else
        echo -e "   ${GREEN}✅ Audio encoded: $AUDIO_SIZE (stereo at $AUDIO_BITRATE)${NC}"
    fi

    # 3.4 MULTIPLEX
    echo -e "   ${YELLOW}📦 Multiplexing...${NC}"
    echo -e "\n--- MULTIPLEX LOG ---" >> "$LOG_FILE"
    # -R11: Strict VCD sector alignment for hardware player compatibility
    # Prevents macroblocking artifacts on real VCD hardware
    mplex -f 1 -b 46 -R11 -o "compliant.mpg" "temp_audio.mp2" "temp_video.m1v" >> "$LOG_FILE" 2>&1

    if grep -q "data will arrive too late" "$LOG_FILE"; then
         echo -e "${RED}⚠️  WARNING: Buffer starvation detected!${NC}"
    fi
    
    FINAL_SIZE=$(portable_du "compliant.mpg")
    echo -e "   ${GREEN}✅ Final MPEG: $FINAL_SIZE${NC}"



    # Truncate volume label to 32 chars (ISO 9660 limit)
    local VOLUME_LABEL="${CLEAN_NAME}${DISC_SUFFIX}"
    VOLUME_LABEL="${VOLUME_LABEL:0:32}"

    # 3.5 / 3.6 GENERATE IMAGE
    if [ "$MISTER_MODE" == "true" ]; then
        echo -e "   ${YELLOW}💿 Building Disc Image (MiSTer mode — no size limit)...${NC}"
        build_image_mister "$LOG_FILE" "$VOLUME_LABEL"
    else
        echo -e "   ${YELLOW}📝 Generating XML...${NC}"
        generate_vcd_xml "videocd.xml" "$VOLUME_LABEL" "$USE_CDIVCD" "$CDI_FIX_DIR" "$MISTR_APP" "$MISTR_BASENAME_UPPER"
        echo -e "   ${YELLOW}💿 Building Disc Image...${NC}"
        echo -e "\n--- IMAGE BUILD LOG ---" >> "$LOG_FILE"
        vcdxbuild --progress videocd.xml >> "$LOG_FILE" 2>&1
    fi

    if [ -f "videocd.bin" ]; then
        mv videocd.bin "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.bin"
        sed "s|videocd.bin|${CLEAN_NAME}${DISC_SUFFIX}.bin|g" videocd.cue > "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.cue"
        rm videocd.cue

        DISC_SIZE=$(portable_du "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.bin")
        echo -e "${GREEN}✅ Finished: $OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.bin ($DISC_SIZE)${NC}"

        # 3.7 AUTO-CHD
        if command -v chdman &> /dev/null; then
            echo -e "   ${YELLOW}🗜️  Compressing to CHD...${NC}"
            # Remove existing CHD if it exists
            if [ -f "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.chd" ]; then
                rm "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.chd"
            fi
            chdman createcd -i "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.cue" -o "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.chd" >> "$LOG_FILE" 2>&1
            if [ -f "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.chd" ]; then
                CHD_SIZE=$(portable_du "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.chd")
                echo -e "${GREEN}✅ Created CHD: $OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.chd ($CHD_SIZE)${NC}"
                # Optional: rm "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.bin" "$OUTPUT_DIR/${CLEAN_NAME}${DISC_SUFFIX}.cue"
            fi
        fi
        echo -e "${CYAN}   📋 Log saved to: $LOG_FILE${NC}"
    else
        echo -e "${RED}❌ Image creation failed.${NC}"
    fi


    # 3.8 CREATE LAX VERSION IF REQUESTED
    if [ "$LAX_MODE" == true ]; then
        echo -e "\n${CYAN}🔧 Creating LAX version (without -R11)...${NC}"
        echo -e "\n--- MULTIPLEX LOG (LAX VERSION) ---" >> "$LOG_FILE"
        
        # Multiplex without -R11
        mplex -f 1 -b 46 -o "compliant_lax.mpg" "temp_audio.mp2" "temp_video.m1v" >> "$LOG_FILE" 2>&1
        
        LAX_SIZE=$(portable_du "compliant_lax.mpg")
        echo -e "   ${GREEN}✅ Final MPEG (lax): $LAX_SIZE${NC}"
        
        # Generate lax XML
        generate_vcd_xml "videocd_lax.xml" "$CLEAN_NAME" "$USE_CDIVCD" "$CDI_FIX_DIR" "$MISTR_APP" "$MISTR_BASENAME_UPPER"
        
        # Build lax image
        echo -e "   ${YELLOW}💿 Building Disc Image (lax)...${NC}"
        vcdxbuild --progress videocd_lax.xml >> "$LOG_FILE" 2>&1
        
        if [ -f "videocd.bin" ]; then
            mv videocd.bin "$OUTPUT_DIR/${CLEAN_NAME}_lax.bin"
            sed "s|videocd.bin|${CLEAN_NAME}_lax.bin|g" videocd.cue > "$OUTPUT_DIR/${CLEAN_NAME}_lax.cue"
            rm videocd.cue
            
            LAX_DISC_SIZE=$(portable_du "$OUTPUT_DIR/${CLEAN_NAME}_lax.bin")
            echo -e "${GREEN}✅ Finished (lax): $OUTPUT_DIR/${CLEAN_NAME}_lax.bin ($LAX_DISC_SIZE)${NC}"
            
            # Create lax CHD
            if command -v chdman &> /dev/null; then
                echo -e "   ${YELLOW}🗜️  Compressing to CHD (lax)...${NC}"
                [ -f "$OUTPUT_DIR/${CLEAN_NAME}_lax.chd" ] && rm "$OUTPUT_DIR/${CLEAN_NAME}_lax.chd"
                chdman createcd -i "$OUTPUT_DIR/${CLEAN_NAME}_lax.cue" -o "$OUTPUT_DIR/${CLEAN_NAME}_lax.chd" >> "$LOG_FILE" 2>&1
                if [ -f "$OUTPUT_DIR/${CLEAN_NAME}_lax.chd" ]; then
                    LAX_CHD_SIZE=$(portable_du "$OUTPUT_DIR/${CLEAN_NAME}_lax.chd")
                    echo -e "${GREEN}✅ Created CHD (lax): $OUTPUT_DIR/${CLEAN_NAME}_lax.chd ($LAX_CHD_SIZE)${NC}"
                fi
            fi
        else
            echo -e "${RED}❌ Image creation failed (lax).${NC}"
        fi
        
        # Cleanup lax temporary files
        rm -f compliant_lax.mpg videocd_lax.xml
        
        echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  COMPARISON TEST: Two versions created for hardware testing   ║${NC}"
        echo -e "${CYAN}║  Strict: ${CLEAN_NAME}.chd (with -R11 -V 46)                  ║${NC}"
        echo -e "${CYAN}║  Lax:    ${CLEAN_NAME}_lax.chd (no -R11, -V 46)               ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    fi
    
    rm -f temp_video.m1v temp_audio.mp2 compliant.mpg videocd.xml
}

# ==============================================================================
#  MAIN EXECUTION
# ==============================================================================
if [ "$QUALITY_MODE" == "ultra" ]; then
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           ULTRA QUALITY MODE - MAXIMUM SETTINGS                ║${NC}"
    echo -e "${YELLOW}║  This will take SIGNIFICANTLY longer than fast mode           ║${NC}"
    echo -e "${YELLOW}║  Use --fast flag for faster encoding with good quality        ║${NC}"
    if [ "$LAX_MODE" == true ]; then
        echo -e "${YELLOW}║  LAX MODE: Creating both strict (-R11) and lax versions       ║${NC}"
    fi
    if [ "$AUDIO_MODE" != "stereo" ]; then
        echo -e "${YELLOW}║  AUDIO: $AUDIO_MODE mode enabled                               ║${NC}"
    fi
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              FAST MODE - GOOD QUALITY, FASTER SPEED            ║${NC}"
    echo -e "${GREEN}║  Use without --fast flag for ultra quality mode               ║${NC}"
    if [ "$LAX_MODE" == true ]; then
        echo -e "${GREEN}║  LAX MODE: Creating both strict (-R11) and lax versions       ║${NC}"
    fi
    if [ "$AUDIO_MODE" != "stereo" ]; then
        echo -e "${GREEN}║  AUDIO: $AUDIO_MODE mode enabled                               ║${NC}"
    fi
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
fi

install_deps
setup_bridge
mkdir -p "$INPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [ -z "$(ls -A $INPUT_DIR)" ]; then
    echo -e "${RED}⚠️  Input folder is empty! Place videos in $INPUT_DIR${NC}"; exit 1
fi

for video in "$INPUT_DIR"/*; do
    [ -e "$video" ] || continue
    [ -d "$video" ] && continue
    FILENAME=$(basename "$video")

    # IGNORE NON-VIDEO FILES
    if [[ "$FILENAME" == .* ]] || \
       [[ "$FILENAME" == *.chd ]] || \
       [[ "$FILENAME" == *.bin ]] || \
       [[ "$FILENAME" == *.cue ]] || \
       [[ "$FILENAME" == *.iso ]] || \
       [[ "$FILENAME" == *.log ]]; then
       continue
    fi

    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$video" 2>/dev/null | grep -q "video"; then
        continue
    fi

    TOTAL_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null)

    if [ "$MISTER_MODE" == "false" ] && (( $(echo "${TOTAL_DURATION:-0} > $MAX_DISC_SECONDS" | bc -l) )); then
        NUM_DISCS=$(awk -v d="$TOTAL_DURATION" -v m="$MAX_DISC_SECONDS" 'BEGIN{n=int(d/m); if(d-n*m>0) n++; print n}')
        SEG_DURATION=$(awk -v d="$TOTAL_DURATION" -v n="$NUM_DISCS" 'BEGIN{printf "%.3f", d/n}')
        echo -e "${CYAN}📀 Long video ($(printf '%.0f' "$TOTAL_DURATION")s). Splitting evenly into $NUM_DISCS discs (~$(printf '%.0f' "$SEG_DURATION")s each)...${NC}"
        for disc in $(seq 1 "$NUM_DISCS"); do
            START=$(awk -v n="$((disc-1))" -v s="$SEG_DURATION" 'BEGIN{printf "%.3f", n*s}')
            process_video "$video" "$START" "$SEG_DURATION" "$disc"
        done
    else
        process_video "$video"
    fi
done

echo -e "\n${GREEN}🎉 BATCH COMPLETE!${NC}"
