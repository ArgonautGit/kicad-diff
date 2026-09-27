#!/usr/bin/env bash
# Commit changes under $RENDER_DIR and push them to the branch that triggered
# the workflow. Meant to run as a step of action.yml.
#
# With AMEND=true on a push event, the renders are folded into the pushed
# commit and force-pushed, guarded by a lease on that commit. If the branch
# has moved on since, they are committed separately instead.

set -euo pipefail

: "${RENDER_DIR:?}" "${COMMIT_MESSAGE:?}"

bot='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
export GIT_COMMITTER_NAME='github-actions[bot]'
export GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

out=${GITHUB_OUTPUT:-/dev/null}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

git add -A -- "$RENDER_DIR"
if git diff --cached --quiet; then
	echo "Renders are up to date."
	echo "changed=false" >>"$out"
	exit 0
fi
echo "changed=true" >>"$out"

{
	echo '### Updated KiCad renders'
	echo '```'
	git diff --cached --stat
	echo '```'
} | tee -a "$summary"

if [[ ${GITHUB_REF:-} != refs/heads/* ]]; then
	git commit -q --author="$bot" -m "$COMMIT_MESSAGE"
	echo "::warning::Not triggered from a branch (${GITHUB_REF:-unknown}), renders were not pushed."
	exit 0
fi
branch=${GITHUB_REF#refs/heads/}

if [[ ${AMEND:-false} == true && ${GITHUB_EVENT_NAME:-} == push ]]; then
	pushed=$(git rev-parse HEAD)
	git commit -q --amend --no-edit --no-verify
	if git push --force-with-lease="$branch:$pushed" origin "HEAD:$branch"; then
		echo "Amended renders into $(git log -1 --format='%h %s')"
		exit 0
	fi
	echo "::warning::$branch moved since $pushed was pushed; committing renders separately."
	git reset -q --soft "$pushed"
fi

git commit -q --author="$bot" -m "$COMMIT_MESSAGE"

# Someone may have pushed while we were rendering; rebase onto their work.
for attempt in 1 2 3; do
	git push origin "HEAD:$branch" && exit 0
	echo "Push failed (attempt $attempt), rebasing onto origin/$branch"
	git pull -q --rebase --autostash origin "$branch"
done
echo "::error::Could not push renders to $branch"
exit 1
