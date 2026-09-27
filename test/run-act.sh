#!/usr/bin/env bash
# End-to-end test of the action using act (https://github.com/nektos/act), so
# no GitHub Actions minutes are used.
#
# A local bare repository plays GitHub. A full clone plays the designer's
# machine, and every workflow run gets a fresh depth-1 clone, like
# actions/checkout on GitHub. Scenarios:
#   1. first run renders every project and pushes a commit
#   2. after editing one schematic only that project's renders change
#   3. a run with nothing changed pushes nothing
#   4. amend mode folds the renders into the pushed commit, keeps the history,
#      and the designer catches up with pull --rebase
#   5. amend mode never overwrites a commit pushed while rendering

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
remote=$work/remote.git
designer=$work/designer
ci=$work/ci

# The act job runs as root, so the CI clone ends up owned by root.
remove_ci() {
	[[ -e $ci ]] && docker run --rm -u 0 -v "$work:/work" "$image" rm -rf /work/ci
	return 0
}
cleanup() {
	remove_ci
	rm -rf "$work"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

new_clone() {
	git clone -q "file://$remote" "$1"
	git -C "$1" config user.name designer
	git -C "$1" config user.email designer@example.com
}

# Check out the current tip the way actions/checkout does, for the next run.
ci_checkout() {
	remove_ci
	git clone -q --depth 1 "file://$remote" "$ci"
}

run_act() {
	echo "=== act: $1"
	(cd "$ci" && act push --bind \
		-P "ubuntu-latest=$runner_image" \
		--local-repository "test/kicad-diff@v1=$here" \
		--container-options "-v $remote:$remote") >"$work/act.log" 2>&1 || {
		cat "$work/act.log"
		fail "act run failed"
	}
	grep -E '^\[.*\]   \| (Rendering|Up to date|Removing|Amended|::warning)' "$work/act.log" |
		sed 's/.*| /    /'
	git -C "$designer" pull -q --rebase origin main
}

push_change() {
	git -C "$designer" commit -qam "$1"
	git -C "$designer" push -q origin main
}

edit_value() {
	sed -i "0,/\"$1\"/s//\"$2\"/" "$designer/complex_hierarchy/ampli_ht.kicad_sch"
}

tip() { git --git-dir="$remote" rev-parse main; }
last_msg() { git --git-dir="$remote" log -1 --format=%s main; }
changed_files() { git --git-dir="$remote" diff --name-only main~1 main; }
history_length() { git --git-dir="$remote" rev-list --count main; }

git init -q --bare -b main "$remote"
git init -q -b main "$designer"
git -C "$designer" config user.name designer
git -C "$designer" config user.email designer@example.com
git -C "$designer" remote add origin "file://$remote"

# Demo projects: a hierarchical design, a 4-layer board and a path with a space.
docker run --rm -u "$(id -u):$(id -g)" -v "$designer:/repo" "$image" bash -c '
	cp -r /usr/share/kicad/demos/complex_hierarchy /repo/
	mkdir -p /repo/boards
	cp -r /usr/share/kicad/demos/video "/usr/share/kicad/demos/sonde xilinx" /repo/boards/'

mkdir -p "$designer/.github/workflows"
sed -E 's#uses: [^ ]+/kicad-diff@[^ ]+#uses: test/kicad-diff@v1#' \
	"$here/examples/kicad-svg.yml" >"$designer/.github/workflows/kicad-svg.yml"
git -C "$designer" add -A
git -C "$designer" commit -qm "Add projects"
git -C "$designer" push -q origin main

# 1
ci_checkout
run_act "initial render"
[[ $(last_msg) == "Update KiCad SVG renders"* ]] || fail "no render commit was pushed"
for f in complex_hierarchy/sch/ampli_ht_vertical.svg boards/video/pcb/In1_Cu.svg \
	"boards/sonde xilinx/sch/sonde xilinx.svg"; do
	git --git-dir="$remote" cat-file -e "main:kicad-svg/$f" || fail "missing kicad-svg/$f"
done
echo "ok: initial renders pushed"

# 2
edit_value 4.7nF 22nF
push_change "Change C203 to 22nF"
ci_checkout
run_act "after editing one schematic"
[[ $(last_msg) == "Update KiCad SVG renders"* ]] || fail "no render commit after edit"
unexpected=$(changed_files | grep -v '^kicad-svg/complex_hierarchy/' || true)
[[ -z $unexpected ]] || fail "unrelated renders changed: $unexpected"
changed_files | grep -q 'sch/ampli_ht_vertical.svg' || fail "edited sheet was not re-rendered"
echo "ok: only the edited project changed"

# 3
before=$(tip)
ci_checkout
run_act "with nothing changed"
[[ $(tip) == "$before" ]] || fail "a commit was pushed without changes"
echo "ok: no-op run pushed nothing"

# 4
sed -i '/uses: test\/kicad-diff@v1/a\        with:\n          amend: true' \
	"$designer/.github/workflows/kicad-svg.yml"
git -C "$designer" commit -qam "Enable amend mode"
edit_value 22nF 33nF
push_change "Change C203 to 33nF"
parent=$(git -C "$designer" rev-parse HEAD~1)
length=$(history_length)
ci_checkout
run_act "amend mode"
[[ $(last_msg) == "Change C203 to 33nF" ]] || fail "tip is not the amended commit: $(last_msg)"
[[ $(git --git-dir="$remote" log -1 --format=%P main) == "$parent" ]] ||
	fail "amended commit has the wrong parent; history was rewritten"
[[ $(history_length) == "$length" ]] || fail "history length changed from $length to $(history_length)"
[[ $(git --git-dir="$remote" log -1 --format=%an main) == designer ]] || fail "author of the amended commit changed"
changed_files | grep -q 'kicad-svg/complex_hierarchy/sch/ampli_ht_vertical.svg' ||
	fail "renders are not in the amended commit"
echo "ok: renders amended into the pushed commit, history intact"
[[ $(git -C "$designer" rev-parse HEAD) == $(tip) ]] ||
	fail "designer's pull --rebase did not land on the amended commit"
[[ -z $(git -C "$designer" status --porcelain) ]] || fail "designer's tree dirty after pull --rebase"
echo "ok: designer caught up with pull --rebase"

# 5
edit_value 33nF 47nF
push_change "Change C203 to 47nF"
ci_checkout
colleague=$work/colleague
new_clone "$colleague"
echo notes >"$colleague/NOTES.md"
git -C "$colleague" add NOTES.md
git -C "$colleague" commit -qm "Add notes"
git -C "$colleague" push -q origin main
length=$(history_length)
run_act "amend mode after the branch moved"
[[ $(last_msg) == "Update KiCad SVG renders"* ]] || fail "expected a separate render commit: $(last_msg)"
[[ $(git --git-dir="$remote" log -1 --format=%s main~1) == "Add notes" ]] || fail "the concurrent push was lost"
[[ $(history_length) == $((length + 1)) ]] || fail "history was rewritten"
echo "ok: concurrent push kept, renders committed separately"

echo "PASS"
