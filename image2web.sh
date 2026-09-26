## Purpose
# - Converts all JPG/PNG images in the current directory to AVIF (`libavif/aom`, tuned for minimum file size).
# - Optionally downscales images to a max edge length beforehand (never upscales).
#
## Usage
# - `zsh scripts/image2web.sh [max_dimension]`
#
## Examples
# - `zsh scripts/image2web.sh`        -> encoding only, no resize
# - `zsh scripts/image2web.sh 3840`   -> resize to max 3840 px + encoding
#
## Location
# - Images: `~/Documents/Terminal`
# - Script: `~/Documents/Terminal/scripts`
#
## Dependencies
# - `sips` (macOS)
# - `libavif` (Homebrew)

# A glob matching nothing expands to nothing (not to the literal `*.jpg`).
setopt NULL_GLOB
# Case-insensitive globbing, so `*.jpg` also matches `.JPG/.JPEG` etc.
setopt NO_CASE_GLOB

# Dependency check:

command -v sips >/dev/null || {
	echo "Error: \`sips\` not found. This script requires macOS." >&2
	exit 1
}

command -v avifenc >/dev/null || {
	echo "Error: \`avifenc\` not found. Install with \`brew install libavif\`." >&2
	exit 1
}

# Optional first arg: max edge length in px. Empty = no resizing.
MAX_DIM="$1"

# Validate only if an argument was actually passed (empty = valid "encode only" mode).
# Regex `^[1-9][0-9]*$` = positive integer, no `0` and no leading zeros – `0` would make `sips -Z 0` fail, and the guard for that is cheaper up front than mid-loop.
if [[ -n "$MAX_DIM" ]] && ! [[ "$MAX_DIM" =~ ^[1-9][0-9]*$ ]]; then
	echo "Error: \`$MAX_DIM\` is not a valid number (positive integer) for the max edge length." >&2  # >&2 = stderr
	echo "Usage: \`$0 [max_dimension]\`" >&2
	echo "Example: \`$0 3840\` -> with resize" >&2
	echo "Example: \`$0\` -> without resize" >&2
	exit 1
fi

mkdir -p out

# Counters for the end-of-run summary.
success_count=0
skipped_count=0
fail_count=0
failed_files=()

# Returns the path to encode from: a resized copy if the longer edge exceeds.
# `MAX_DIM`, otherwise the original file (never upscales).
# IMPORTANT: this function "returns" its result by echoing a path to `stdout`, which the caller captures via `$(…)`.
# So only the final path may go to `stdout` – every diagnostic must go to stderr (>&2), or it would end up inside the captured value.
resize_if_needed() {
	local f="$1"
	local info w h longest

	# One `sips` call for BOTH dimensions = fewer process spawns than querying width and height separately.
	# `2>/dev/null` hides `sips`’s own errors on unreadable files.
	info="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null)"
	# Anchor on the `pixelWidth:` token (with colon) so a path line that merely contains the substring `pixelWidth` can’t be mis-parsed. `$2` is the number.
	# `<<<` feeds `$info` to `awk` as `stdin` (here-string).
	w="$(awk '/pixelWidth:/ {print $2}' <<< "$info")"
	h="$(awk '/pixelHeight:/ {print $2}' <<< "$info")"

	# If `sips` failed (corrupt/empty/unsupported file), `w` or `h` is empty.
	# Warn, then hand back the original path so encoding is still attempted (and can fail cleanly on its own) instead of aborting the whole batch here.
	if [[ -z "$w" || -z "$h" ]]; then
		echo "Warning: could not read dimensions for \`$f\`, skipping resize." >&2
		echo "$f"
		return
	fi

	# `zsh` arithmetic ternary: the longer of the two edges.
	# Implicitly also covers square images (`w == h`): the condition `w > h` is false, so the ternary falls into the `h` branch – but since both are equal, it doesn’t matter which one gets picked.
	longest=$(( w > h ? w : h ))

	# `sips -Z` scales the LONGER axis to `MAX_DIM` (shorter axis follows the aspect ratio automatically), but it does this unconditionally in BOTH directions.
	# The strict `> MAX_DIM` check is what prevents upscaling images that are already at or below the target – `sips` itself has no "downscale only" mode.
	if (( longest > MAX_DIM )); then
		mkdir -p temp-resized
		sips -Z "$MAX_DIM" "$f" --out "temp-resized/$f" >/dev/null
		# Return: the resized copy.
		echo "temp-resized/$f"
	else
		# Return: the untouched original.
		echo "$f"
	fi
}

# Per-file pipeline: skip existing output -> (optionally) resize -> encode -> count.
# Args: filename, `yuv` format, color quality, alpha quality ("" = none, JPG case).
process() {
	local f="$1" yuv="$2" q="$3" qalpha="$4"
	# The extension is APPENDED, not replaced, so `image.jpg` becomes `image.jpg.avif` to avoid conflicts when files with different extensions have the same name.
	local out="out/${f}.avif"
	local src="$f"

	# Skip files already converted. Decided HERE, not via `avifenc`’s exit code, because `avifenc --no-overwrite` returns non-zero on an existing file – which would otherwise be miscounted as a "failure" on every re-run.
	# Skipping early also avoids a pointless resize pass for files that won’t be re-encoded.
	if [[ -e "$out" ]]; then
		# Pre-increment returns the NEW value -> stays `exit-0`.
		(( ++skipped_count ))
		# Even on `0->1` (matters only if `set -e` is ever added).
		return
	fi

	# Only resize when a max dimension was actually given.
	[[ -n "$MAX_DIM" ]] && src="$(resize_if_needed "$f")"

	# Build the `--qalpha` flag only when a value was passed (PNG).
	# An empty array expands to nothing, so JPG calls `avifenc` entirely without the alpha flag.
	local -a alpha_arg=()
	[[ -n "$qalpha" ]] && alpha_arg=(--qalpha "$qalpha")

	# Encode to AVIF with `libaom`, tuned for smallest files with no time budget:
	#   --codec aom          Slowest but highest-compression `AV1` encoder for stills.
	#   -s 0                 Slowest speed = encoder explores the most options -> best compression.
	#   -d 8                 8-bit output; JPG/PNG sources are 8-bit, so `10/12` would only add bytes.
	#   -y <yuv>             Chroma subsampling: `420` for photos (invisible), `444` for sharp edges/text.
	#   -q <q>               Color quality `0..100`; lower = smaller + lossier.
	#   --qalpha <q>         Alpha (transparency) quality; PNG only, injected via `alpha_arg`.
	#   -r full              Full-range `YUV`; matches web sRGB, avoids washed-out colors in browsers.
	#   -j 1                 Single-threaded; multi-thread tiling can slightly reduce compression.
	#   --ignore-exif/-xmp   Strip metadata -> fewer bytes, no visual impact.
	#   --no-overwrite       Never clobber existing output (race safety net; skip is handled above).

	# The if-condition uses `avifenc`’s exit code directly (`0` = success).
	if avifenc \
		--codec aom \
		-s 0 \
		-d 8 \
		-y "$yuv" \
		-q "$q" \
		"${alpha_arg[@]}" \
		-r full \
		-j 1 \
		--ignore-exif \
		--ignore-xmp \
		--no-overwrite \
		"$src" "$out"
	then
		(( ++success_count ))
	else
		(( ++fail_count ))
		# Remember the name for the failure list at the end.
		failed_files+=("$f")
	fi
}

# JPG/JPEG: `4:2:0` chroma is fine for photographic content, moderate quality.
for f in *.jpg *.jpeg; do
	# Guard against edge cases where the glob yields a non-file.
	[[ -f "$f" ]] || continue
	# `yuv=420`, `q=45`, no `qalpha`.
	process "$f" 420 45 ""
done

# PNG: `4:4:4` chroma (preserves sharp edges/text), higher quality + separate alpha quality.
for f in *.png; do
	[[ -f "$f" ]] || continue
	# `yuv=444`, `q=55`, `qalpha=85`.
	process "$f" 444 55 85
done

# Temp-resized is created lazily (only if something was actually resized), so guard the cleanup on its existence rather than on `MAX_DIM` being set.
if [[ -d temp-resized ]]; then
	rm -rf temp-resized
fi

echo ""
echo "Done. Results in \`./out\`"
echo "Succeeded: $success_count | Skipped: $skipped_count | Failed: $fail_count"

# List failures explicitly (`stderr`), but only if there are any – keeps a clean run’s output short.
if (( fail_count > 0 )); then
	echo "Failed files:" >&2
	for ff in "${failed_files[@]}"; do
		echo "  - $ff" >&2
	done
fi

# Non-zero exit when anything failed, so the script is usable in pipelines/CI (e.g. `zsh image2web.sh 3840 && rsync out/ server:…`).
exit $(( fail_count > 0 ? 1 : 0 ))
