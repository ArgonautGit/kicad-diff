#!/usr/bin/env bash
# End-to-end test of the action using act (https://github.com/nektos/act), so
# no GitHub Actions minutes are used.
#
# Builds a throwaway repository from KiCad's demo projects with a local bare
# repository as its "origin", then runs examples/kicad-svg.yml against this
# checkout of the action:
#   1. first run renders every project and pushes a commit
#   2. after editing one schematic only that project's renders change
#   3. a run with nothing changed pushes nothing

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
kicad_version=${KICAD_VERSION:-10.0.6}
image=kicad/kicad:$kicad_version
runner_image=${RUNNER_IMAGE:-catthehacker/ubuntu:act-latest}

command -v act >/dev/null || {
	echo "act not found. Install it, or on NixOS run: nix-shell -p act --run $0" >&2
	exit 1
}

work=$(mktemp -d)
# The act job runs as root, so some files end up owned by root.
cleanup() {
	docker run --rm -u 0 -v "$work:/work" "$image" rm -rf /work/consumer /work/remote.git
	rm -rf "$work"
}
trap cleanup EXIT

remote=$work/remote.git
repo=$work/consumer

git init -q --bare -b main "$remote"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
git -C "$repo" remote add origin "$remote"

# Demo projects: a hierarchical design, a 4-layer board and a path with a space.
docker run --rm -u "$(id -u):$(id -g)" -v "$repo:/repo" "$image" bash -c '
	cp -r /usr/share/kicad/demos/complex_hierarchy /repo/
	mkdir -p /repo/boards
	cp -r /usr/share/kicad/demos/video "/usr/share/kicad/demos/sonde xilinx" /repo/boards/'

mkdir -p "$repo/.github/workflows"
sed -E 's#uses: [^ ]+/kicad-diff@[^ ]+#uses: test/kicad-diff@v1#' \
	"$here/examples/kicad-svg.yml" >"$repo/.github/workflows/kicad-svg.yml"

git -C "$repo" add -A
git -C "$repo" commit -qm "Add projects"
git -C "$repo" push -q origin main

run_act() {
	echo "=== act: $1"
	(cd "$repo" && act push --bind \
		-P "ubuntu-latest=$runner_image" \
		--local-repository "test/kicad-diff@v1=$here" \
		--container-options "-v $remote:$remote") >"$work/act.log" 2>&1 || {
		cat "$work/act.log"
		echo "FAIL: act run failed" >&2
		exit 1
	}
	grep -E '^\[.*\]   \| (Rendering|Up to date|Removing)' "$work/act.log" | sed 's/.*| /    /'
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

last_msg() { git --git-dir="$remote" log -1 --format=%s main; }
changed_files() { git --git-dir="$remote" diff --name-only main~1 main; }

run_act "initial render"
[[ $(last_msg) == "Update KiCad SVG renders"* ]] || fail "no render commit was pushed"
for f in complex_hierarchy/sch/ampli_ht_vertical.svg boards/video/pcb/In1_Cu.svg \
	"boards/sonde xilinx/sch/sonde xilinx.svg"; do
	git --git-dir="$remote" cat-file -e "main:kicad-svg/$f" || fail "missing kicad-svg/$f"
done
echo "ok: initial renders pushed"

git -C "$repo" pull -q --rebase origin main
sed -i '0,/"4.7nF"/s//"22nF"/' "$repo/complex_hierarchy/ampli_ht.kicad_sch"
git -C "$repo" commit -qam "Change C203 to 22nF"
git -C "$repo" push -q origin main

run_act "after editing one schematic"
[[ $(last_msg) == "Update KiCad SVG renders"* ]] || fail "no render commit after edit"
unexpected=$(changed_files | grep -v '^kicad-svg/complex_hierarchy/' || true)
[[ -z $unexpected ]] || fail "unrelated renders changed: $unexpected"
changed_files | grep -q 'sch/ampli_ht_vertical.svg' || fail "edited sheet was not re-rendered"
echo "ok: only the edited project changed"

head=$(git --git-dir="$remote" rev-parse main)
run_act "with nothing changed"
[[ $(git --git-dir="$remote" rev-parse main) == "$head" ]] || fail "a commit was pushed without changes"
echo "ok: no-op run pushed nothing"

echo "PASS"
