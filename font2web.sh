## Purpose
# - Converts all TTF/OTF fonts in the current directory into one heavily optimized WOFF2 each, tuned for the smallest web delivery.
# - The loss is deliberately invisible: only unused Unicode blocks, TrueType hinting and non-essential metadata are dropped, while every OpenType layout feature (kerning, ligatures, stylistic sets) survives 1:1.
# - For variable fonts an optional axis spec is applied first, which either pins the font to a static instance or narrows an axis range – both shrink the file far beyond what plain subsetting can.
# - Prints ready-to-paste `@font-face` markup with the family name and weight range read back from the finished file.
#
## Usage
# - `zsh scripts/font2web.sh [unicode] [axis_spec]`
#
## Examples
# - `zsh scripts/font2web.sh`                             -> Latin/Europe subset, variable fonts left intact
# - `zsh scripts/font2web.sh full`                        -> every glyph kept, hinting/metadata still stripped
# - `zsh scripts/font2web.sh latin wght=400`              -> Latin subset, variable fonts pinned to Regular
# - `zsh scripts/font2web.sh latin wght=300:700`          -> Latin subset, still variable but only weight 300 – 700
# - `zsh scripts/font2web.sh "U+0020-007E,U+00C0-00FF"`   -> custom unicode ranges
#
## Location
# - Fonts:  `~/Documents/Terminal`
# - Script: `~/Documents/Terminal/scripts`
#
## Dependencies
# - `fonttools` (Homebrew)

# A glob matching nothing expands to nothing (not to the literal `*.ttf`).
setopt NULL_GLOB
# Case-insensitive globbing, so `*.ttf` also matches `.TTF/.OTF` etc.
setopt NO_CASE_GLOB

# Dependency check:
command -v fonttools >/dev/null || {
	echo "Error: \`fonttools\` not found. Install with \`brew install fonttools\`." >&2
	exit 1
}

# === Positional args ===
# `$1`: Unicode scope. Empty or `latin` uses the preset below, `full` keeps every glyph, anything starting with `U+` is taken as a literal range list.
# `$2`: Variable-font axis spec, handed straight to the instancer. A value WITH a colon (`wght=300:700`) narrows the range and keeps the font variable; one WITHOUT (`wght=400`) pins it to a static instance. Multiple axes are comma-separated. Empty leaves variable fonts fully intact.
UNICODE_ARG="$1"
AXIS_SPEC="$2"

# === Unicode preset for the `latin` scope ===
# Covers every Latin-script language plus the full set of typographic, technical and pictographic symbols, while leaving out the writing systems that make a font genuinely heavy.
# Being generous here is essentially free: `pyftsubset` intersects this list with the glyphs the font actually contains, so any range the font does not carry costs exactly zero bytes.
# This is deliberately WIDER than Google Fonts’ `latin` + `latin-ext`. Google splits a font into many small files and therefore keeps only `U+2191`/`U+2193` of the arrows and only `U+2074` of the superscripts; this script produces ONE file, so the whole symbol blocks go in instead.
# The array is joined into a comma-separated string below, which is what lets every single range carry its own comment.
LATIN_RANGES=(
	# === Letters ===
	"U+0020-007E"   # Basic Latin, printable ASCII: `A–Z`, `a–z`, `0–9` and plain keyboard punctuation. `U+0000-001F` are control characters with no glyphs and stay out.
	"U+00A0-00FF"   # Latin-1 Supplement: German, French, Spanish and Nordic letters (`Ä Ö Ü ß é è ñ å ø æ`) plus `© ® ° ± × ÷ µ § ¶ « » ¡ ¿ ¼ ½ ¾ £ ¥ ¢`.
	"U+0100-017F"   # Latin Extended-A: Polish, Czech, Hungarian, Turkish, Maltese, Serbo-Croatian and the Baltic languages (`ą ć ę ł ń ś ź ż ő ű ğ ı`).
	"U+0180-024F"   # Latin Extended-B: the comma-below forms `Ș ș Ț ț` that modern Romanian requires (Latin Extended-A only has the cedilla variants, which count as wrong today), plus Croatian digraphs, Slovenian and historic/African letters.
	"U+0250-02AF"   # IPA Extensions: phonetic alphabet, including `ə` (schwa), which Azerbaijani uses as a regular letter.
	"U+02B0-02FF"   # Spacing Modifier Letters: standalone accents and the modifier apostrophe (`ʼ ˆ ˇ ˘ ˙ ˚ ˛ ˜ ˝`), used by Czech, Slovak and Hungarian typography.
	"U+0300-036F"   # Combining Diacritical Marks: needed when text arrives decomposed, i.e. letter and accent as separate codepoints rather than one precomposed character.
	"U+1D00-1DBF"   # Phonetic Extensions: small-capital and superscript letterforms for phonetic notation.
	"U+1E00-1E9F"   # Latin Extended Additional, first half: Welsh (`ẃ ŵ ẅ`), academic transliteration, and `ẞ` (capital sharp s) at `U+1E9E`.
	"U+1EF2-1EFF"   # Latin Extended Additional, tail: Welsh `ỳ` and the remaining Y forms.
	"U+2C60-2C7F"   # Latin Extended-C: medieval and minority-language letters. Almost no font carries these, which is exactly why listing them is free.
	"U+A720-A7FF"   # Latin Extended-D: same category, mostly historic and phonetic.

	# === Punctuation and symbols ===
	"U+2000-206F"   # General Punctuation: en/em dash, typographic quotes (`‘ ’ “ ”`), `† ‡ • … ‰ ‹ › ′ ″`, plus the invisible spacing characters and the Zero Width Joiner `U+200D` that emoji sequences are built from.
	"U+2070-209F"   # Superscripts and Subscripts: `⁰ ⁴ ⁵ … ₀ ₁ ₂`. Note that `¹ ² ³` themselves live in Latin-1, so both blocks are needed for a complete set.
	"U+20A0-20CF"   # Currency Symbols: `€ ₽ ₺ ₹ ₴ ₿` and the rest; `£ ¥ ¢` come from Latin-1.
	"U+20D0-20FF"   # Combining Diacritical Marks for Symbols, which is where `U+20E3` (the keycap enclosure) lives – the piece that turns `1` into `1️⃣`.
	"U+2100-214F"   # Letterlike Symbols: `™ № ℓ ℮ ℃ Ω`. `©` and `®` sit in Latin-1, but `™` does NOT – this block is the only way to get it.
	"U+2150-218F"   # Number Forms: `⅓ ⅔ ⅛ ⅜` and Roman numerals (`¼ ½ ¾` are in Latin-1).
	"U+2190-21FF"   # Arrows: `← ↑ → ↓ ↔ ⇒ ⇔`.
	"U+2200-22FF"   # Mathematical Operators: true minus `−` (typographically distinct from the hyphen), `∞ ≈ ≠ ≤ ≥ √ ∑ ∆ ∈ ∫`.
	"U+2300-23FF"   # Miscellaneous Technical: `⌘ ⌥ ⇧ ⌫ ⏎` for keyboard-shortcut notation, plus the media controls `⏯ ⏸ ⏹ ⏪ ⏩`.
	"U+25A0-25FF"   # Geometric Shapes: `■ □ ▪ ▲ ► ● ○ ◆`, the usual bullets and list markers.
	"U+2600-26FF"   # Miscellaneous Symbols: `★ ☆ ☐ ☑ ♠ ♥ ♦ ♣ ☀ ☁ ☎ ⚠ ⚡ ⚽`. Many of these render as emoji on their own, which is why they stay in.
	"U+2700-27BF"   # Dingbats: `✓ ✔ ✗ ✘ ✂ ✈ ❤ ➜ ➡`.
	"U+2B00-2BFF"   # Miscellaneous Symbols and Arrows: the heavy arrows `⬅ ⬆ ⬇ ➡`, `⭐`, `⬛ ⬜` and `⏺`. A real gap in most subset presets, and one that ordinary fonts DO sometimes carry.
	"U+2E00-2E7F"   # Supplemental Punctuation: rarer editorial and scholarly marks.
	"U+FB00-FB06"   # Latin ligature codepoints `ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ`. Modern fonts form these through the OpenType `liga` feature instead, but some still map the codepoints directly.
	"U+FE00-FE0F"   # Variation Selectors: `U+FE0E` forces the text rendering of a dual-purpose character, `U+FE0F` forces the emoji one (`❤` versus `❤️`). Without these a font cannot honour either request.
	"U+FEFF"        # Zero-width no-break space, the byte-order mark. Google keeps it, purely defensively.
	"U+FFFD"        # Replacement character `�`, shown when text cannot be decoded.

	# === Emoji (above the BMP) ===
	# Ordinary text fonts do not carry these: emoji ship in dedicated color fonts such as Apple Color Emoji or Noto Color Emoji, using `COLR`/`CPAL`, `sbix` or `CBDT` tables.
	# So for a normal webfont these ranges are a no-op and cost nothing – but if a font DOES include them, they are kept instead of silently dropped.
	"U+1F1E6-1F1FF"   # Regional Indicator Symbols: the letter pairs that combine into flags (`🇩🇪`).
	"U+1F300-1F5FF"   # Miscellaneous Symbols and Pictographs: weather, objects, hands, hearts – the bulk of the older emoji set.
	"U+1F600-1F64F"   # Emoticons: the faces (`😀 😅 🙏`).
	"U+1F680-1F6FF"   # Transport and Map Symbols (`🚀 🚗 ✈️`).
	"U+1F900-1F9FF"   # Supplemental Symbols and Pictographs: the newer faces, gestures and objects (`🤔 🧠 🦊`).
	"U+1FA70-1FAFF"   # Symbols and Pictographs Extended-A: the most recent additions (`🩵 🪐 🫶`).
)

# Deliberately EXCLUDED, because this is where a font’s real weight sits and none of it is needed for European text:
#   Greek (`U+0370-03FF`, `U+1F00-1FFF`), Cyrillic (`U+0400-04FF`), Hebrew, Arabic, Thai, Devanagari and CJK.
#   `U+1EA0-1EF1` – the Vietnamese core of Latin Extended Additional. Google gives Vietnamese its own subset for the same reason: it is a large block that European text never touches.
#   `U+1D400-1D7FF` – the mathematical alphabets (`𝐀 𝒜 𝔸`), which belong to `MathML` or `KaTeX` on the web rather than to a text font.

# `${(j:,:)…}` joins the array into the single comma-separated string `pyftsubset` expects.
LATIN="${(j:,:)LATIN_RANGES}"

# Resolve `$1` into the single flag handed to `pyftsubset`.
# `full` uses `--unicodes=*`, kept inside a variable so the `*` never reaches `zsh`’s globbing – everything survives while hinting and metadata are still stripped below.
case "$UNICODE_ARG" in
	""|latin) UNICODE_FLAG="--unicodes=$LATIN" ;;
	full)     UNICODE_FLAG="--unicodes=*" ;;
	U+*)      UNICODE_FLAG="--unicodes=$UNICODE_ARG" ;;
	*)
		echo "Error: \`$UNICODE_ARG\` is not a valid Unicode scope." >&2
		echo "Use \`latin\` (default), \`full\`, or a range list starting with \`U+\`." >&2
		echo "Usage: \`$0 [unicode] [axis_spec]\`" >&2
		exit 1
		;;
esac

# Validate the axis spec only if one was passed (empty is the valid "leave variable fonts alone" mode).
# A single malformed spec would fail the instancer on EVERY variable font, so the guard is cheaper up front than per file – same reasoning as the `MAX_DIM` check in `image2web.sh`.
if [[ -n "$AXIS_SPEC" ]] && ! [[ "$AXIS_SPEC" =~ '^[A-Za-z]{1,4}=[0-9.]+(:[0-9.]+)?(,[A-Za-z]{1,4}=[0-9.]+(:[0-9.]+)?)*$' ]]; then
	echo "Error: \`$AXIS_SPEC\` is not a valid axis spec." >&2
	echo "Expected e.g. \`wght=400\` (pin) or \`wght=300:700\` (range), comma-separated for several axes." >&2
	exit 1
fi

mkdir -p out

# Counters for the end-of-run summary.
# Each input produces exactly ONE output here, so there are no doubled increments as in the two-tier a/v scripts.
success_count=0
skipped_count=0
fail_count=0
failed_files=()
snippets=()

# Returns the path to subset FROM: an instanced copy when the font is variable AND an axis spec was given, otherwise the original.
# Same contract as `resize_if_needed()` in `image2web.sh`: the result is returned by echoing ONE path to `stdout` and captured via `$(…)`, so every diagnostic must go to `stderr` or it would land inside the captured value.
instance_if_needed() {
	local f="$1"

	# No axis spec means there is nothing to instance.
	[[ -z "$AXIS_SPEC" ]] && { echo "$f"; return; }

	# A static font has no `fvar` table and the instancer does not apply to it.
	# `ttx -l` lists the tables present, and the first column holds the tag.
	if ! ttx -l "$f" 2>/dev/null | awk '{print $1}' | grep -qx fvar; then
		echo "$f"
		return
	fi

	mkdir -p temp-instanced
	local inst="temp-instanced/$f"

	# `${(s:,:)AXIS_SPEC}` splits the spec on commas, unquoted on purpose so each `tag=value` becomes its own argument.
	# The instancer decides pin vs. range from the colon inside each value, which is why no separate mode flag is needed.
	if fonttools varLib.instancer "$f" ${(s:,:)AXIS_SPEC} -o "$inst" >/dev/null 2>&1; then
		echo "$inst"
	else
		# Hand back the original so this font is still subset instead of aborting the batch – same fallback stance as the failed dimension read in `image2web.sh`.
		echo "Warning: instancer failed for \`$f\` with axis spec \`$AXIS_SPEC\`, subsetting the original instead." >&2
		echo "$f"
	fi
}

# Builds the `@font-face` block by reading the FINISHED WOFF2 back, the same way `codec_string()` reads the encoded WebM in `video2web.sh` – the markup has to describe what actually landed on disk, not what was intended.
# Returns failure without emitting anything when the family name cannot be read, so a broken file produces a warning instead of misleading CSS.
font_face_block() {
	local out="$1" f="$2"
	local tmp
	local -a dump_args meta

	tmp="$(mktemp)" || return 1

	# `name` and `OS/2` exist in every font; `fvar` only in variable ones, and requesting a missing table can make the dump fail.
	# So the table list is checked first and `fvar` added only when it is really there.
	dump_args=(-t name -t "OS/2")
	if ttx -l "$out" 2>/dev/null | awk '{print $1}' | grep -qx fvar; then
		dump_args+=(-t fvar)
	fi

	if ! ttx -q "${dump_args[@]}" -o "$tmp" "$out" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi

	# One `awk` pass over the dump collects every field at once, the same "read it all in one call" approach used for `sips` and `ffprobe` in the other scripts.
	# `${(@f)…}` splits the result on newlines into [family, weight, style].
	meta=("${(@f)$(awk '
		# In `ttx` output a name record holds its text on the FOLLOWING line, which is why each match pulls the next line with `getline`.
		# The closing quote in the pattern is what keeps `nameID="1"` from also matching `16` and `17`.
		/<namerecord nameID="16"/ { getline v; gsub(/^[ \t]+|[ \t\r]+$/, "", v); if (n16 == "") n16 = v }
		/<namerecord nameID="1"/  { getline v; gsub(/^[ \t]+|[ \t\r]+$/, "", v); if (n1  == "") n1  = v }
		/<namerecord nameID="17"/ { getline v; gsub(/^[ \t]+|[ \t\r]+$/, "", v); if (n17 == "") n17 = v }
		/<namerecord nameID="2"/  { getline v; gsub(/^[ \t]+|[ \t\r]+$/, "", v); if (n2  == "") n2  = v }

		# Static weight, e.g. `<usWeightClass value="400"/>`.
		/<usWeightClass value=/ { if (match($0, /value="[0-9]+"/)) wcls = substr($0, RSTART + 7, RLENGTH - 8) }

		# The `wght` axis sits inside an `<Axis>` block, so a flag marks that the following Min/Max belong to it.
		/<AxisTag>wght<\/AxisTag>/ { inw = 1 }
		inw && /<MinValue>/ { v = $0; gsub(/[^0-9.]/, "", v); wmin = v }
		inw && /<MaxValue>/ { v = $0; gsub(/[^0-9.]/, "", v); wmax = v; inw = 0 }

		END {
			# `nameID` 16 is the typographic family, the correct grouping key for variable and extended families; 1 is the legacy fallback.
			fam = n16; if (fam == "") fam = n1

			if (wmin != "" && wmax != "" && wmin + 0 != wmax + 0)
				# Still variable across weight, so CSS gets a RANGE – that is what unlocks `font-weight: 300 700` in the browser.
				wt = int(wmin) " " int(wmax)
			else if (wcls != "")
				wt = wcls
			else
				wt = "normal"

			# Reading italic off the subfamily name is more reliable than decoding the `fsSelection` bitfield out of the XML.
			sfam = n17; if (sfam == "") sfam = n2
			st = (sfam ~ /[Ii]talic/) ? "italic" : "normal"

			print fam
			print wt
			print st
		}
	' "$tmp")}")

	rm -f "$tmp"

	# Without a family name the CSS would be useless, so this counts as a failed read.
	[[ ${#meta} -ge 3 && -n "${meta[1]}" ]] || return 1

	# `font-display: swap` is a deliberate web default: text paints immediately in a fallback face and swaps to the webfont once it arrives, instead of blocking the render.
	print -r -- "@font-face {
  font-family: \"${meta[1]}\";
  src: url(\"${f}.woff2\") format(\"woff2\");
  font-weight: ${meta[2]};
  font-style: ${meta[3]};
  font-display: swap;
}"
}

# Per-file pipeline: skip existing output -> (optionally) instance -> subset to WOFF2 -> count -> collect markup.
process() {
	local f="$1"
	# The extension is APPENDED, not replaced, so `Inter.ttf` becomes `Inter.ttf.woff2`.
	# Same collision reasoning as the other scripts: a `.ttf` and an `.otf` sharing a basename would both target `Inter.woff2`, and since existing outputs are skipped, one would silently shadow the other.
	local out="out/${f}.woff2"
	local src="$f"
	local block

	# Skip files already converted, decided HERE rather than through the tool’s exit code, so a re-run completes an interrupted batch without recounting finished work as failure.
	# Skipping early also avoids a pointless instancer pass.
	if [[ -e "$out" ]]; then
		# Pre-increment returns the NEW value, so this stays `exit-0` even on `0->1` (matters only if `set -e` is ever added).
		(( ++skipped_count ))
		return
	fi

	src="$(instance_if_needed "$f")"

	# Subset and compress in a single `pyftsubset` pass:
	#   --flavor=woff2            Brotli-compressed WOFF2, the only web font format worth shipping today – and unlike images, video and audio, it needs NO fallback tier, because every browser in use supports it.
	#   $UNICODE_FLAG             Either the Latin preset, a custom range list, or `*` for everything. By far the biggest size lever, since glyph outlines are the bulk of any font file.
	#   --layout-features=’*’     Keeps every OpenType feature (`kern`, `liga`, `dlig`, `ss01…`, `calt`, `onum`). Without it `pyftsubset` retains only a curated default set and would quietly drop stylistic sets and discretionary ligatures – exactly the design details a font was chosen for. Features referencing removed glyphs are pruned automatically, so `*` carries nothing dead.
	#   --no-hinting              Drops TrueType hinting instructions. Browsers rasterize through their own engine and never use them, yet on many fonts these tables are a large share of the file.
	#   --no-glyph-names          Human-readable glyph names play no part in rendering.
	#   --no-legacy-cmap          Removes obsolete `cmap` subtables kept for pre-Unicode systems.
	#   --no-symbol-cmap          Removes the Windows symbol-encoding `cmap`, irrelevant for web text.
	#   --no-notdef-outline       Drops the outline of `.notdef`, so a missing glyph renders as blank instead of a box.
	#   --no-recommended-glyphs   Stops `pyftsubset` from force-keeping glyphs that the Unicode range did not ask for.
	#   --name-IDs=…              Keeps only the records that matter: `0` (copyright, retained because many font licenses require the notice to survive), `1`/`2` (family and subfamily) and `16`/`17` (typographic family and subfamily for variable families). Everything else – vendor URLs, sample text, version strings – goes.
	#   --drop-tables+=DSIG       The digital signature is void the moment a font is modified, so it is pure dead weight.
	#
	# Deliberately NOT set:
	#   --desubroutinize          Would flatten CFF subroutines, which only pays off for uncompressed or gzipped CFF. Under WOFF2’s Brotli it saves close to nothing while slowing the run – same "left out on purpose" reasoning as `-ac`/`-ar` in `audio2web.sh`.
	#
	# `stderr` is deliberately NOT silenced: a real error (a corrupt font, or a build without `brotli`) has to be visible, otherwise every file would just be counted as failed with no explanation.

	if pyftsubset "$src" \
		--output-file="$out" \
		--flavor=woff2 \
		"$UNICODE_FLAG" \
		--layout-features='*' \
		--no-hinting \
		--no-glyph-names \
		--no-legacy-cmap \
		--no-symbol-cmap \
		--no-notdef-outline \
		--no-recommended-glyphs \
		--name-IDs='0,1,2,16,17' \
		--drop-tables+=DSIG
	then
		(( ++success_count ))

		# Build the markup only if the result can be described correctly; a warning beats emitting CSS with the wrong family name.
		if block="$(font_face_block "$out" "$f")"; then
			snippets+=("$block")
			snippets+=("")
		else
			echo "Warning: could not read font metadata from \`$out\` – write its \`@font-face\` by hand." >&2
		fi
	else
		(( ++fail_count ))
		# Remember the name for the failure list at the end.
		failed_files+=("$f")
	fi
}

# One loop over the two source formats, with no branching on extension: unlike images, where `.jpg` meant photo and `.png` meant graphic, a `.ttf` and an `.otf` differ only in outline format and take identical treatment.
# `.woff` and `.woff2` are deliberately left out – they are delivery formats, like `.webm` in the a/v scripts, and re-subsetting an already shipped font is not this script’s job.
for f in *.ttf *.otf; do
	# Guard against edge cases where the glob yields a non-file.
	[[ -f "$f" ]] || continue
	process "$f"
done

# `temp-instanced` is created lazily (only when something was actually instanced), so the cleanup is guarded on its existence rather than on `AXIS_SPEC` being set.
if [[ -d temp-instanced ]]; then
	rm -rf temp-instanced
fi

echo ""
echo "Done. Results in \`./out\`"
echo "Succeeded: $success_count | Skipped: $skipped_count | Failed: $fail_count"

# Print the markup block only when there is something to paste.
if (( ${#snippets} > 0 )); then
	echo ""
	echo "=== CSS ==="
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

# Non-zero exit when anything failed, so the script is usable in pipelines/CI (e.g. `zsh font2web.sh && rsync out/ server:…`).
exit $(( fail_count > 0 ? 1 : 0 ))
