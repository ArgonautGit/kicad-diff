#!/usr/bin/env bash
# Render every KiCad project under a directory to SVG (one file per schematic
# sheet and per PCB layer) so changes can be reviewed as image diffs.
#
# A project is only re-rendered when its inputs change. Each output directory
# holds a .stamp with a hash of the project's source files, the KiCad version
# and the render settings; a missing or different stamp triggers a render.
#
# By default kicad-cli runs inside the official kicad/kicad Docker image so
# local renders are byte-identical to CI renders.

set -euo pipefail

usage() {
	cat <<EOF
Usage: $(basename "$0") [options] [DIR]

Render all KiCad projects (*.kicad_pro) under DIR (default: .) to SVG.

Options:
  -o, --output DIR          Output directory, relative to DIR (default: kicad-svg)
  -l, --layers LIST         PCB layers to export, one SVG each
                            (default: $DEFAULT_LAYERS)
  -c, --common-layers LIST  Layers drawn on every PCB SVG (default: Edge.Cuts)
  -k, --kicad-version VER   kicad/kicad image tag (default: 10.0.6)
  -f, --force               Re-render even if the stamp is up to date
      --no-docker           Use the kicad-cli on PATH instead of Docker
  -h, --help                Show this help
EOF
}

DEFAULT_LAYERS='*.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts,F.Courtyard,B.Courtyard'
# Bump when a change to this script alters the SVGs it produces, so existing
# renders are regenerated.
FORMAT_VERSION=1

output=kicad-svg
layers=$DEFAULT_LAYERS
common_layers=Edge.Cuts
kicad_version=10.0.6
force=false
use_docker=true
dir=.

while (($#)); do
	case $1 in
	-o | --output) output=$2; shift 2 ;;
	-l | --layers) layers=$2; shift 2 ;;
	-c | --common-layers) common_layers=$2; shift 2 ;;
	-k | --kicad-version) kicad_version=$2; shift 2 ;;
	-f | --force) force=true; shift ;;
	--no-docker) use_docker=false; shift ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	*) dir=$1; shift ;;
	esac
done

output=${output%/}
[[ -z $output || $output == /* || $output == *..* ]] && {
	echo "--output must be a relative path inside DIR" >&2
	exit 2
}

# Re-run this script inside the KiCad image, with DIR mounted as /project.
if $use_docker && [[ -z ${KICAD_DIFF_IN_CONTAINER:-} ]]; then
	image=kicad/kicad:$kicad_version
	docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null
	args=(--output "$output" --layers "$layers" --common-layers "$common_layers" --no-docker)
	$force && args+=(--force)
	exec docker run --rm -i \
		-v "$(realpath "$dir"):/project" -w /project \
		-u "$(id -u):$(id -g)" -e HOME=/tmp -e KICAD_DIFF_IN_CONTAINER=1 \
		"$image" bash -s -- "${args[@]}" . <"${BASH_SOURCE[0]}"
fi

command -v kicad-cli >/dev/null || {
	echo "kicad-cli not found" >&2
	exit 1
}
cd "$dir"

settings="format=$FORMAT_VERSION kicad=$(kicad-cli version) layers=$layers common=$common_layers"

# find(1) arguments that skip hidden directories (.git, .history, ...) and the
# output directory.
prune=(\( -name '.?*' -o -path "./$output" \) -prune -o)

# Print the stamp for a project: its path plus a hash of everything that
# affects the renders.
stamp_for() {
	local pro=$1 pdir q nested=()
	pdir=$(dirname "$pro")
	# Skip subdirectories that hold their own project.
	for q in "${project_dirs[@]}"; do
		[[ $q != "$pdir" && $q == "$pdir"/* ]] && nested+=(-o -path "$q")
	done
	echo "project: ${pro#./}"
	{
		echo "$settings"
		find "$pdir" \( -name '.?*' -o -path "./$output" "${nested[@]}" \) -prune -o -type f \
			\( -name '*.kicad_sch' -o -name '*.kicad_pcb' -o -name '*.kicad_wks' \) \
			! -name '_autosave-*' ! -name '~*' -print0 |
			LC_ALL=C sort -z | xargs -0 -r sha256sum
		sha256sum "$pro"
	} | sha256sum | sed 's/ .*//; s/^/inputs: /'
}

# Remove the timestamp kicad-cli writes into every SVG, and drop the
# "<project>-" prefix from file names.
normalize() {
	local dir=$1 name=$2 f base
	for f in "$dir"/*.svg; do
		[[ -e $f ]] || continue
		sed -i '/^<title>SVG Image created as .*<\/title>$/d' "$f"
		base=$(basename "$f")
		[[ $base == "$name-"* ]] && mv "$f" "$dir/${base#"$name-"}"
	done
}

render_project() {
	local pro=$1 pdir name dest stamp tmp
	pdir=$(dirname "$pro")
	name=$(basename "$pro" .kicad_pro)
	# <output>/<project dir>, plus /<name> unless the directory is already
	# named after the project.
	dest=$output/${pdir#./}
	[[ $pdir == . || $(basename "$pdir") != "$name" ]] && dest=$dest/$name
	dest=${dest//\/.\//\/}
	stamp=$(stamp_for "$pro")
	current_dests[$dest]=1

	if ! $force && [[ -f $dest/.stamp && $(<"$dest/.stamp") == "$stamp" ]]; then
		echo "Up to date: ${pro#./}"
		return
	fi
	echo "Rendering: ${pro#./}"

	tmp=$(mktemp -d)
	if [[ -f $pdir/$name.kicad_sch ]]; then
		kicad-cli sch export svg --exclude-drawing-sheet \
			--output "$tmp/sch" "$pdir/$name.kicad_sch" >/dev/null || return 1
		normalize "$tmp/sch" "$name"
	fi
	if [[ -f $pdir/$name.kicad_pcb ]]; then
		kicad-cli pcb export svg --mode-multi --exclude-drawing-sheet --page-size-mode 0 \
			--layers "$layers" --common-layers "$common_layers" \
			--output "$tmp/pcb" "$pdir/$name.kicad_pcb" >/dev/null || return 1
		normalize "$tmp/pcb" "$name"
	fi
	echo "$stamp" >"$tmp/.stamp"

	rm -rf "$dest"
	mkdir -p "$(dirname "$dest")"
	mv "$tmp" "$dest"
	chmod -R u=rwX,go=rX "$dest"
}

mapfile -d '' projects < <(find . "${prune[@]}" -type f -name '*.kicad_pro' -print0 | LC_ALL=C sort -z)
if ((${#projects[@]} == 0)); then
	echo "No KiCad projects found."
	exit 0
fi

declare -A current_dests=()
project_dirs=()
for pro in "${projects[@]}"; do
	project_dirs+=("$(dirname "$pro")")
done

failed=0
for pro in "${projects[@]}"; do
	render_project "$pro" || {
		echo "::error::Failed to render ${pro#./}" >&2
		failed=1
	}
done

# Delete renders that no current project maps to (deleted or moved projects).
if [[ -d $output ]]; then
	while IFS= read -r -d '' s; do
		d=$(dirname "$s")
		if [[ -z ${current_dests[$d]:-} ]]; then
			echo "Removing stale renders: $d"
			rm -rf "$d"
		fi
	done < <(find "$output" -name .stamp -print0)
	find "$output" -mindepth 1 -type d -empty -delete
fi

exit $failed
