## Purpose
# - Converts all common audio files in the current directory into a web-ready pair: a modern WebM (`Opus`) and an M4A fallback (`AAC`) that plays everywhere.
# - Video files are accepted too and reduced to their audio track, so a voice-over, an interview or a podcast recording can be published as audio without a detour through a separate export.
# - Prints ready-to-paste `<source>` markup for the `<audio>` element.
#
## Usage
# - `zsh scripts/audio2web.sh`
#
## Location
# - Audio: `~/Documents/Terminal`
# - Script: `~/Documents/Terminal/scripts`
#
## Dependencies
# - `FFmpeg` (Homebrew)

# A glob matching nothing expands to nothing (not to the literal `*.wav`).
setopt NULL_GLOB
# Case-insensitive globbing, so `*.wav` also matches `.WAV/.MP3` etc.
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

# No `codec_string()` helper here, unlike `video2web.sh`.
# `AV1` needed one because its profile, level and bit depth vary per file and have to be read back with `ffprobe`.
# Audio has no such variance: `Opus` has no profile or level variants at all, and `FFmpeg`’s native `AAC` encoder only ever produces `AAC-LC`.
# Both codec strings are therefore static and can be hardcoded into the markup below.

# Reports whether the file carries at least one audio stream.
# Only worth the extra `ffprobe` call because video files are valid input here: a permanently muted hero video is a legitimate file, not a broken one, and it should be reported as skipped instead of failing with a cryptic `ffmpeg` error.
# `-select_streams a` restricts the query to audio, so empty output means there is none.
has_audio() {
	local streams
	streams="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null)"
	[[ -n "$streams" ]]
}

# Per-file pipeline: check for audio -> skip existing output -> encode both tiers -> count -> collect markup.
process() {
	local f="$1"
	local suffix=""

	# Video inputs get an extra `.audio-only` infix, audio inputs do not.
	# Reason: `video2web.sh` accepts the same four video extensions and writes `out/clip.mp4.webm` for the very same source.
	# Without the infix both scripts would target that one path, and since both skip on an existing output, one would silently leave the other’s file in place – a video WebM where an audio-only one was expected, with nothing in the log to show for it.
	# `${f:e}` is `zsh`’s extension modifier, the surrounding `${…:l}` lowercases it, so `.MOV` matches too (`NO_CASE_GLOB` lets those into the loop).
	case "${${f:e}:l}" in
		mp4|mov|m4v|mkv) suffix=".audio-only" ;;
	esac

	# The extension is APPENDED, not replaced, so `track.wav` becomes `track.wav.webm` and `interview.mov` becomes `interview.mov.audio-only.webm`.
	# Same reasoning as in `image2web.sh` and `video2web.sh`: ten input extensions map onto two output extensions, so replacing would silently collide (`song.wav` and `song.mp3` in one folder would fight over `song.webm`).
	local webm_out="out/${f}${suffix}.webm"
	local m4a_out="out/${f}${suffix}.m4a"

	# A file with no audio at all is nothing this script can do anything with, so it is reported and skipped rather than run into an `ffmpeg` error.
	# Both counters are raised because every other input yields TWO outputs – otherwise the summary would not add up.
	if ! has_audio "$f"; then
		echo "Skipping \`$f\` – no audio stream." >&2
		(( ++skipped_count ))
		(( ++skipped_count ))
		return
	fi

	# Audio encoding is fast, but naming the file makes a failure traceable to its source.
	echo "Processing: $f"

	# Args shared by both encodes:
	#   -nostdin           `ffmpeg` reads `stdin` by default and would otherwise swallow the loop.
	#   -hide_banner       Drops the version/config header.
	#   -loglevel error    Only real errors; progress is printed by the script itself.
	#   -n                 Never overwrite (race safety net; the actual skip is handled above).
	#   -map 0:a:0         Exactly the first audio stream, which does three jobs at once here:
	#                      it drops the video track when the input is a video file, it excludes embedded cover art (which `MP3` and `M4A` carry as a VIDEO stream, usually `MJPEG`), and it picks a single track out of an edit-suite export that ships a stereo mix plus separate stems.
	#                      Neither a `?` nor a separate `-vn` is needed: the missing-audio case is already handled by `has_audio()` above.
	#   -map_metadata -1   Strips container metadata: title, artist, album and any device info the source carried.
	#   -map_chapters -1   Chapter marks are meaningless for web assets.
	#
	# Two things are deliberately NOT set in either encode:
	#   -ac                Forcing a channel count would break the automatic adaptation: a mono voice memo stays mono and costs half the data, a stereo track stays stereo, without the script having to know which is which.
	#   -ar                `Opus` always runs at 48 kHz internally and resamples itself, and `AAC` simply keeps the source rate; setting it would resample twice.

	# === Modern tier: WebM/Opus ===
	#   -c:a libopus       `Opus` is the reason this tier exists – at a given bitrate it beats `AAC` clearly, and audio IS the whole file here, unlike in video where the codec choice moves only a few percent.
	#   -b:a 96k           This is a VBR TARGET, not a fixed rate, which is why one value covers both speech and music: a sparse voice recording lands well below it on its own, while music gets the headroom it needs.
	#                      Same self-adapting behaviour that `CRF` provides on the video side.
	#   -cues_to_front 1   Writes the seek index to the start of the file – the WebM equivalent of `+faststart`, since Matroska has no `moov` atom.
	#
	# Note on the container: `.opus` (`Opus` in `Ogg`) would be the "native" extension, but it is the wrong choice for the web – `Safari` does not read `Ogg` at all, on any platform.
	# `Opus` in WebM is supported from `Safari` 17 onwards, which makes WebM the same modern container used by `video2web.sh`.

	if [[ -e "$webm_out" ]]; then
		# Pre-increment returns the NEW value, so this stays `exit-0` even on `0->1` (matters only if `set -e` is ever added).
		(( ++skipped_count ))
	elif ffmpeg \
		-nostdin \
		-hide_banner \
		-loglevel error \
		-n \
		-i "$f" \
		-map 0:a:0 \
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
		failed_files+=("$f (WebM/Opus)")
	fi

	# === Fallback tier: M4A/AAC ===
	#   -c:a aac               `FFmpeg`’s native `AAC` encoder, which produces `AAC-LC` – the one audio codec that plays everywhere inside `MP4`.
	#                          `libfdk_aac` would encode slightly better but is not in Homebrew builds, because its license is incompatible with distributing `FFmpeg` binaries.
	#                          `MP3` was ruled out: it is equally universal but measurably worse per bitrate, and nothing on the web still requires it.
	#   -b:a 128k              Roughly matches `Opus` at 96k in perceived quality – the same efficiency gap that puts `CRF` 40 against 27 on the video side.
	#   -movflags +faststart   Moves the `moov` atom to the front so playback starts before the full file is downloaded, which is mandatory for web.
	#
	# The `.m4a` extension makes `FFmpeg` pick the `ipod` muxer, which is the `MP4` family variant intended for audio-only files.

	if [[ -e "$m4a_out" ]]; then
		(( ++skipped_count ))
	elif ffmpeg \
		-nostdin \
		-hide_banner \
		-loglevel error \
		-n \
		-i "$f" \
		-map 0:a:0 \
		-c:a aac \
		-b:a 128k \
		-map_metadata -1 \
		-map_chapters -1 \
		-movflags +faststart \
		"$m4a_out"
	then
		(( ++success_count ))
	else
		(( ++fail_count ))
		failed_files+=("$f (M4A/AAC)")
	fi

	# Build the markup only if the WebM actually exists.
	# The fallback deliberately carries NO `codecs` parameter: it is the last `<source>` in the list, so there is nothing left to fall through to and nothing for the browser to decide.
	if [[ -e "$webm_out" ]]; then
		snippets+=("  <source src=\"${f}${suffix}.webm\" type=\"audio/webm; codecs=opus\">")
		snippets+=("  <source src=\"${f}${suffix}.m4a\" type=\"audio/mp4\">")
		snippets+=("")
	fi
}

# One loop, one setting – no speech/music mode.
# `Opus` is VBR and the channel count is inherited from the source, so a single 96k target serves a mono voice memo and a stereo track equally well without an argument to pick between them.
# Lossless sources (`.wav`, `.aiff`, `.aif`, `.flac`) are the ideal input; the lossy ones (`.mp3`, `.m4a`) stack a second generation of loss but are far too common to leave out.
# The four video extensions mirror `video2web.sh` and let the script pull the audio track straight out of a clip – `-map 0:a:0` drops the video stream, so nothing else in the pipeline has to change.
# `.opus`, `.ogg` and `webm` are deliberately absent – they are delivery formats, and re-encoding them would only add generation loss.
for f in *.wav *.aiff *.aif *.flac *.mp3 *.m4a *.mp4 *.mov *.m4v *.mkv; do
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

# Non-zero exit when anything failed, so the script is usable in pipelines/CI (e.g. `zsh audio2web.sh && rsync out/ server:…`).
exit $(( fail_count > 0 ? 1 : 0 ))
