## Purpose
# - Strips every document-level metadata field from all PDFs in the current directory and rebuilds each file for the web.
# - The page content is left completely untouched: no image re-encoding, no downsampling, no colour conversion, no font re-embedding. Links and annotations survive intact.
# - Output is linearized ("Fast Web View"), so a browser renders the first page before the file has finished downloading.
#
## Usage
# - `zsh scripts/pdf2web.sh`
#
## Location
# - PDFs:   `~/Documents/Terminal`
# - Script: `~/Documents/Terminal/scripts`
#
## Dependencies
# - `ExifTool` (Homebrew)
# - `QPDF` (Homebrew)

# A glob matching nothing expands to nothing (not to the literal `*.pdf`).
setopt NULL_GLOB
# Case-insensitive globbing, so `*.pdf` also matches `.PDF`.
setopt NO_CASE_GLOB

# Dependency check:

command -v exiftool >/dev/null || {
	echo "Error: \`exiftool\` not found. Install with \`brew install exiftool\`." >&2
	exit 1
}

command -v qpdf >/dev/null || {
	echo "Error: \`qpdf\` not found. Install with \`brew install qpdf\`." >&2
	exit 1
}

mkdir -p out

# Counters for the end-of-run summary.
# Each input produces exactly ONE output here, so there are no doubled increments as in the two-tier a/v scripts.
success_count=0
skipped_count=0
fail_count=0
failed_files=()

# Per-file pipeline: skip existing output -> strip metadata on a copy -> rebuild into `out/` -> count.
process() {
	local f="$1"
	# The extension is NOT appended here, unlike in the other scripts: input and output are both `.pdf`, so `document.pdf.pdf` would be noise rather than collision protection.
	# There is nothing to collide with either – a single input extension maps onto a single output extension, so two different sources can never target the same name.
	local out="out/$f"
	local tmp="temp-stripped/$f"
	local rc

	# Skip files already processed, decided HERE rather than through a tool’s exit code, so a re-run completes an interrupted batch without recounting finished work as failure.
	if [[ -e "$out" ]]; then
		# Pre-increment returns the NEW value, so this stays `exit-0` even on `0->1` (matters only if `set -e` is ever added).
		(( ++skipped_count ))
		return
	fi

	echo "Processing: $f"

	# `exiftool` edits in place, so the source is copied first – the original must never be touched.
	# The temp directory is created lazily, the same way `image2web.sh` only creates `temp-resized` when something actually gets resized.
	mkdir -p temp-stripped
	if ! cp "$f" "$tmp"; then
		(( ++fail_count ))
		failed_files+=("$f (copy)")
		return
	fi

	# === Step 1: null the metadata ===
	# PDF metadata lives in at least two places: the Info dictionary (`Title`, `Author`, `Producer`, `CreationDate` …) and XMP packets holding RDF as XML. `-all:all=` clears both.
	#   -overwrite_original   Without it `exiftool` keeps a `_original` backup beside the file, which would then be copied around as clutter.
	#   -q -q                 Doubly quiet. A single `-q` still lets through a `[minor]` warning on EVERY file, stating that the edits are reversible – true at this exact point, and made false by the `qpdf` rebuild in step 2, so printing it here only misleads.
	#
	# On its own this is NOT enough. `exiftool` works by incremental update: it removes the POINTER to the data and appends the change, while the original bytes stay in the file and can be recovered. Step 2 is what makes the removal real.
	if ! exiftool -all:all= -overwrite_original -q -q "$tmp"; then
		(( ++fail_count ))
		failed_files+=("$f (exiftool)")
		return
	fi

	# === Step 2: rebuild the file ===
	#   --linearize   Reorders the PDF for "Fast Web View" so the first page renders before the download completes – and, in the same pass, rebuilds the file from its live objects, which discards everything step 1 orphaned. One flag covering both requirements.
	#
	# `qpdf` operates on the PDF OBJECT structure and never re-interprets content streams. That is the whole reason this script exists instead of a `Ghostscript` one: `gs -sDEVICE=pdfwrite` regenerates the document from scratch, re-encoding images, converting colour spaces and re-embedding fonts along the way.
	#
	# Deliberately NOT used:
	#   --object-streams=generate / --recompress-flate   Both lossless and both would shrink the file, but they restructure more than the stated goal asks for. The point here is a file that is byte-for-byte as close to the original as metadata removal allows.
	#   --flatten-annotations=all / --empty --pages      Circulate online as "the" qpdf metadata command and break exactly what this script protects: flattening bakes annotations into the page so links go dead, and `--empty --pages` discards document-level data including the named destinations that tables of contents and cross-references point at.
	#
	# The exit code is captured instead of being used as an `if` condition, because `qpdf` distinguishes three outcomes and only one of them is a real failure.
	qpdf --linearize "$tmp" "$out"
	rc=$?

	if (( rc == 0 )); then
		(( ++success_count ))
	elif (( rc == 3 )); then
		# Exit code `3` means the operation SUCCEEDED but the input had defects worth reporting – almost always pre-existing damage in the source (a broken cross-reference offset, for instance) that `qpdf` repaired on the way through. The output file is written and usable.
		# Treating a non-zero exit as failure here would discard a perfectly good result, the same trap as `avifenc --no-overwrite` in `image2web.sh`.
		(( ++success_count ))
		echo "Note: \`$f\` produced qpdf warnings – the output was written, but open it once to confirm." >&2
	else
		(( ++fail_count ))
		# Remember the name for the failure list at the end.
		failed_files+=("$f (qpdf)")
	fi
}

# One loop, one setting, no arguments: unlike the image script there is no dimension to cap, and unlike the a/v scripts there is no quality lever at all, because nothing is re-encoded.
for f in *.pdf; do
	# Guard against edge cases where the glob yields a non-file.
	[[ -f "$f" ]] || continue
	process "$f"
done

# `temp-stripped` is created lazily (only once a file actually reached step 1), so the cleanup is guarded on its existence.
if [[ -d temp-stripped ]]; then
	rm -rf temp-stripped
fi

echo ""
echo "Done. Results in \`./out\`"
echo "Succeeded: $success_count | Skipped: $skipped_count | Failed: $fail_count"

# Verification is left to the user rather than run automatically, because it is a read-only check that belongs in the terminal, not in the batch:
#   exiftool -a -G1 -extractEmbedded "out/FILE.pdf"
#   `-extractEmbedded` matters: XMP carried by embedded objects stays invisible without it.
#
# What this script does NOT remove, so it is known rather than discovered later:
#   - Annotations that carry an author name. Comments and links are the same object class, so dropping one drops the other.
#   - Embedded file attachments.
#   - Pixels. A scanned letterhead is not metadata.

# List failures explicitly (`stderr`), but only if there are any – keeps a clean run’s output short.
if (( fail_count > 0 )); then
	echo "Failed files:" >&2
	for ff in "${failed_files[@]}"; do
		echo "  - $ff" >&2
	done
fi

# Non-zero exit when anything failed, so the script is usable in pipelines/CI (e.g. `zsh pdf2web.sh && rsync out/ server:…`).
exit $(( fail_count > 0 ? 1 : 0 ))
