## Purpose
# - Converts all common video files in the current directory into a web-ready pair: a modern WebM (`AV1` video + `Opus` audio) and an MP4 fallback (`H.264` + `AAC`) that plays everywhere.
# - Prints ready-to-paste `<source>` markup including the correct `AV1` codec string per file.
#
## Usage
# - `zsh scripts/video2web.sh`
#
## Location
# - Videos: `~/Documents/Terminal`
# - Script: `~/Documents/Terminal/scripts`
#
## Dependencies
# - `FFmpeg` (Homebrew)

# A glob matching nothing expands to nothing (not to the literal `*.mp4`).
setopt NULL_GLOB
# Case-insensitive globbing, so `*.mov` also matches `.MOV/.MP4` etc.
setopt NO_CASE_GLOB

# Dependency check:

command -v ffmpeg >/dev/null || {
	echo "Error: \`ffmpeg\` not found. Install with \`brew install ffmpeg\`." >&2
	exit 1
}

mkdir -p out

# Counters for the end-of-run summary.
# Each input produces TWO outputs, counted independently so a half-finished pair gets completed on a re-run.
success_count=0
skipped_count=0
fail_count=0
failed_files=()
snippets=()

# Derives the HTML `codecs` value for an encoded `AV1` file, e.g. `av01.0.08M.10`.
# The format is `av01.P.LLT.DD` = profile . level+tier . bit depth.
# IMPORTANT: a WRONG string is worse than none – the browser silently skips that `<source>` and never gets the small file.
# So every field is guarded and the function returns failure instead of emitting a guess.
codec_string() {
	local f="$1"
	local info profile_raw level_raw pixfmt_raw profile level depth

	# One `ffprobe` call, parsed per field with `awk` (same pattern as the `sips` call in `image2web.sh`).
	# `-F=` splits on the `=` in lines like `profile=Main`, so `$2` is the value.
	info="$(ffprobe -v error -select_streams v:0 \
		-show_entries stream=profile,level,pix_fmt \
		-of default=noprint_wrappers=1 "$f" 2>/dev/null)"
	profile_raw="$(awk -F= '/^profile=/ {print $2}' <<< "$info")"
	level_raw="$(awk -F= '/^level=/ {print $2}' <<< "$info")"
	pixfmt_raw="$(awk -F= '/^pix_fmt=/ {print $2}' <<< "$info")"

	# `ffprobe` reports `-99` (or nothing at all) when the level is unknown, and emitting that would produce an invalid string.
	[[ "$level_raw" =~ ^[0-9]+$ ]] || return 1

	case "$profile_raw" in
		Main) profile=0 ;;
		High) profile=1 ;;
		Professional) profile=2 ;;
		# Anything unexpected: don’t guess.
		*) return 1 ;;
	esac

	# `LL` is `seq_level_idx`, zero-padded to two digits (level 4.0 becomes `08`).
	level="$(printf "%02d" "$level_raw")"

	case "$pixfmt_raw" in
		*10le*|*10be*) depth=10 ;;
		*12le*|*12be*) depth=12 ;;
		*) depth=08 ;;
	esac

	# The tier is hardcoded to Main (`M`): High tier only exists from level 4.0 upwards and is never produced by these settings.
	echo "av01.${profile}.${level}M.${depth}"
}

# Per-file pipeline: skip existing output -> encode both tiers -> count -> collect markup.
process() {
	local f="$1"
	# The extension is APPENDED, not replaced, so `video.mov` becomes `video.mov.webm`.
	# Same reasoning as in `image2web.sh`: four input extensions map onto two output extensions, so replacing would silently collide (`clip.mov` and `clip.mp4` in one folder would fight over `clip.webm`).
	local webm_out="out/${f}.webm"
	local mp4_out="out/${f}.mp4"
	local cs

	# Video encoding runs for minutes per file, so announce what is currently being worked on.
	echo "Processing: $f"

	# Args shared by both encodes:
	#   -nostdin           `ffmpeg` reads `stdin` by default and would otherwise swallow the loop.
	#   -hide_banner       Drops the version/config header.
	#   -loglevel error    Only real errors; progress is printed by the script itself.
	#   -n                 Never overwrite (race safety net; the actual skip is handled above).
	#   -map 0:v:0         Exactly the first video stream – ignores embedded cover art carried as a second "video" stream.
	#   -map "0:a:0?"      Exactly the first audio stream, and only if one exists.
	#                      MUST stay quoted: `?` is a `zsh` glob, and with `NULL_GLOB` an unquoted `0:a?` silently expands to nothing, after which `ffmpeg` eats the next flag as the `-map` value.
	#                      For permanently muted hero videos, swap in `-an` to drop the stream entirely.
	#   -g 240             Keyframe roughly every 8 – 10 s. Scene detection stays ON, so hard cuts still get their own keyframe – disabling it (`-sc_threshold 0`) is what causes seconds of block artifacts after a cut.
	#   -map_metadata -1   Strips container metadata: fewer bytes, and no leaked device or GPS data from phone recordings.
	#   -map_chapters -1   Chapter marks are meaningless for web assets.

	# === Modern tier: WebM/AV1/Opus ===
	#   -c:v libsvtav1          `SVT-AV1`, not `libaom-av1`. Inverse of `image2web.sh`: for stills `libaom` wins, for video it would be unusably slow.
	#   -crf 40                 The only real size lever; everything else here is correctness. Measured on real footage: sits at ~1.2 – 1.5 Mbps for 1080p, inside the 1.0 – 1.8 Mbps web delivery corridor.
	#                           NOT the same scale as x264’s `CRF` – `SVT-AV1` runs 0..63, x264 runs 0..51, and the numbers do not transfer.
	#   -preset 4               0..13, lower = slower. 4 – 6 is the quality range; below 4 costs hours for almost nothing.
	#                           The `-s 0` logic from `image2web.sh` does NOT apply here.
	#   -pix_fmt yuv420p10le    10-bit even from 8-bit sources, because `SVT-AV1` bands far less in gradients this way.
	#                           Measured as free: 25.0 MB in 10-bit vs 25.2 MB in 8-bit on the same clip.
	#                           Safe because `AV1` Main profile covers 8 and 10 bit, and `.10` lands in the codec string so a decoder that can’t handle it falls through to the MP4.
	#                           NEVER `yuv444p`: Android Chrome hands High profile to a hardware decoder that can’t do it, which renders garbage.
	#   -svtav1-params tune=0   Optimizes for subjective quality (`tune=1` chases `PSNR` and looks worse to humans).
	#                           Does NOT work via `ffmpeg`’s `-tune`; it has to go through `-svtav1-params`.
	#   -c:a libopus            The native audio codec in WebM, so there is no container friction here.
	#   -b:a 96k                `Opus` at 64k already matches `AAC` at 96k, but audio is only ~4 – 5 % of the file, so the headroom for music is nearly free.
	#                           Do NOT add `-ar`: `Opus` always runs at 48 kHz internally and resamples itself; forcing it resamples twice.
	#   -cues_to_front 1        Writes the seek index to the start of the file – the WebM equivalent of `+faststart`, since Matroska has no `moov` atom.

	if [[ -e "$webm_out" ]]; then
		# Pre-increment returns the NEW value, so this stays `exit-0` even on `0->1` (matters only if `set -e` is ever added).
		(( ++skipped_count ))
	elif ffmpeg \
		-nostdin \
		-hide_banner \
		-loglevel error \
		-n \
		-i "$f" \
		-map 0:v:0 -map "0:a:0?" \
		-c:v libsvtav1 \
		-crf 40 \
		-preset 4 \
		-pix_fmt yuv420p10le \
		-svtav1-params tune=0 \
		-g 240 \
		-c:a libopus \
		-b:a 96k \
		-map_metadata -1 \
		-map_chapters -1 \
		-cues_to_front 1 \
		"$webm_out"
	then
		(( ++success_count ))
	else
		(( ++fail_count ))
		failed_files+=("$f (WebM/AV1)")
	fi

	# === Fallback tier: MP4/H.264/AAC ===
	#   -crf 27                x264 runs 0..51, useful range 18 – 28. 27 sits near the aggressive end but leaves margin before the blocking that `H.264` shows in dark areas.
	#                          Paired with `AV1` at 40 this lands at roughly 2x the bitrate, which matches what the two codecs actually differ by.
	#   -preset veryslow       x264 uses NAMED presets (`SVT-AV1` uses 0 – 13). Here the slowest setting IS worth it: it costs minutes and buys a real 5 – 10 %.
	#   -profile:v high        Combined with `yuv420p` this is the pairing every browser and device decodes.
	#   -pix_fmt yuv420p       `H.264` stays 8-bit: 10-bit would mean High10 profile, where browser support collapses.
	#                          This is also why the MP4 bands slightly more than the WebM in flat areas, and no `CRF` value can close that gap.
	#                          No `-level:v` is set: x264 derives the minimum level the stream actually needs, which stays correct for 4K input where a hardcoded `4.1` would not.
	#   -x264-params ref=4     Caps reference frames at 4 (`veryslow` defaults to 16).
	#                          This is NOT a compression setting: the reference frame count drives the Decoded Picture Buffer size, which dictates the `H.264` level `x264` has to declare in the header.
	#                          At 4K, `ref=16` needs ~518k macroblocks of DPB, which only level 6.0 allows – and level 6.x was added for 8K in 2016 and is implemented in almost no hardware decoder.
	#                          Result: Apple’s VideoToolbox refuses the stream, playback falls back to software, 4K `H.264` stutters, frames get dropped, and audio drifts out of sync because it keeps running on its own clock.
	#                          `ref=4` keeps the DPB inside level 5.1 at 4K and level 4.0 at 1080p – both universally supported, and derived automatically per resolution, so no hardcoded `-level:v` is needed.
	#   -c:a aac -b:a 96k      The only audio codec that works everywhere inside MP4.
	#   -movflags +faststart   Moves the `moov` atom to the front so playback starts before the full file is downloaded, which is mandatory for web.

	if [[ -e "$mp4_out" ]]; then
		(( ++skipped_count ))
	elif ffmpeg \
		-nostdin \
		-hide_banner \
		-loglevel error \
		-n \
		-i "$f" \
		-map 0:v:0 -map "0:a:0?" \
		-c:v libx264 \
		-crf 27 \
		-preset veryslow \
		-profile:v high \
		-pix_fmt yuv420p \
		-x264-params ref=4 \
		-g 240 \
		-c:a aac \
		-b:a 96k \
		-map_metadata -1 \
		-map_chapters -1 \
		-movflags +faststart \
		"$mp4_out"
	then
		(( ++success_count ))
	else
		(( ++fail_count ))
		failed_files+=("$f (MP4/H.264)")
	fi

	# Build the markup only if the WebM exists AND can be described correctly.
	# Without a valid `codecs` string the browser would pick the WebM blindly, so warning beats emitting something misleading.
	if [[ -e "$webm_out" ]]; then
		if cs="$(codec_string "$webm_out")"; then
			# `Opus` has no profile or level variants, so the audio part is simply `opus`.
			snippets+=("  <source src=\"${f}.webm\" type='video/webm; codecs=\"${cs},opus\"'>")
			snippets+=("  <source src=\"${f}.mp4\" type=\"video/mp4\">")
			snippets+=("")
		else
			echo "Warning: could not derive the `AV1` codec string for \`$webm_out\` – omit the WebM \`<source>\` or determine it by hand." >&2
		fi
	fi
}

# One loop, one setting: unlike images, the input extension says nothing about the content, since a `.mov` and an `.mp4` can hold bit-identical `H.264`.
# `.webm` is deliberately left out – it is a delivery format, and re-encoding it would only stack generation loss.
for f in *.mp4 *.mov *.m4v *.mkv; do
	# Guard against edge cases where the glob yields a non-file.
	[[ -f "$f" ]] || continue
	process "$f"
done

echo ""
echo "Done. Results in \`./out\`"
echo "Succeeded: $success_count | Skipped: $skipped_count | Failed: $fail_count"

# Print the markup block only when there is something to paste.
if (( ${#snippets} > 0 )); then
	echo ""
	echo "=== HTML ==="
	for line in "${snippets[@]}"; do
		echo "$line"
	done
fi

# List failures explicitly (`stderr`), but only if there are any – keeps a clean run’s output short.
if (( fail_count > 0 )); then
	echo "Failed files:" >&2
	for ff in "${failed_files[@]}"; do
		echo "  - $ff" >&2
	done
fi

# Non-zero exit when anything failed, so the script is usable in pipelines/CI (e.g. `zsh video2web.sh && rsync out/ server:…`).
exit $(( fail_count > 0 ? 1 : 0 ))
