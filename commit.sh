#!/usr/bin/env bash
# Commit changes under $RENDER_DIR and push them to the branch that triggered
# the workflow. Meant to run as a step of action.yml.

set -euo pipefail

: "${RENDER_DIR:?}" "${COMMIT_MESSAGE:?}"

export GIT_AUTHOR_NAME='github-actions[bot]'
export GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

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

git commit -q -m "$COMMIT_MESSAGE"

if [[ ${GITHUB_REF:-} != refs/heads/* ]]; then
	echo "::warning::Not triggered from a branch (${GITHUB_REF:-unknown}), renders were not pushed."
	exit 0
fi
branch=${GITHUB_REF#refs/heads/}

# Someone may have pushed while we were rendering; rebase onto their work.
for attempt in 1 2 3; do
	git push origin "HEAD:$branch" && exit 0
	echo "Push failed (attempt $attempt), rebasing onto origin/$branch"
	git pull -q --rebase --autostash origin "$branch"
done
echo "::error::Could not push renders to $branch"
exit 1
