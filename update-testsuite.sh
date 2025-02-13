#!/bin/bash
# Update tests based on upstream repositories.
set -e
set -u
set -o pipefail

non_tests=":(exclude)test/"

repos='
  spec
  threads
  simd
  exception-handling
  gc
  tail-call
  host-bindings
  annotations
  function-references
  memory64
  extended-const
  multi-memory
'

log_and_run() {
    echo ">>" $*
    if ! $*; then
        echo "sub-command failed: $*"
        exit
    fi
}

try_log_and_run() {
    echo ">>" $*
    $*
}

pushdir() {
    pushd $1 >/dev/null || exit
}

popdir() {
    popd >/dev/null || exit
}

update_repo() {
    local repo=$1
    local branch=$2
    pushdir repos
        if [ -d ${repo} ]; then
            log_and_run git -C ${repo} fetch origin
            log_and_run git -C ${repo} reset origin/${branch} --hard
        else
            log_and_run git clone https://github.com/WebAssembly/${repo}
        fi

        # Add upstream spec as "spec" remote.
        if [ "${repo}" != "spec" ]; then
            pushdir ${repo}
                if ! git remote | grep spec >/dev/null; then
                    log_and_run git remote add spec https://github.com/WebAssembly/spec
                fi

                log_and_run git fetch spec
            popdir
        fi
    popdir
}

merge_with_spec() {
    local repo=$1
    local branch=$2

    [ "${repo}" == "spec" ] && return

    pushdir repos/${repo}
        # Create and checkout "try-merge" branch.
        if ! git branch | grep try-merge >/dev/null; then
            log_and_run git branch try-merge origin/${branch}
        fi
        log_and_run git checkout try-merge

        # Attempt to merge with spec/main.
        log_and_run git reset origin/${branch} --hard
        try_log_and_run git merge -q spec/main -m "merged"
        if [ $? -ne 0 ]; then
            # Ignore merge conflicts in non-test directories.
            # We don't care about those changes.
            try_log_and_run git checkout --ours ${non_tests}
            try_log_and_run git add ${non_tests}
            try_log_and_run git -c core.editor=true merge --continue
            if [ $? -ne 0 ]; then
                git merge --abort
                popdir
                return 1
            fi
        fi
    popdir
    return 0
}


echo -e "Update repos\n" > commit_message

failed_repos=

for repo in ${repos}; do
    echo "++ updating ${repo}"
    if [ "${repo}" = "gc" -o \
         "${repo}" = "tail-call" -o \
         "${repo}" = "annotations" -o \
         "${repo}" = "function-references" -o \
         "${repo}" = "multi-memory" ]; then
      branch=master
    else
      branch=main
    fi
    update_repo ${repo} ${branch}

    if ! merge_with_spec ${repo} ${branch}; then
        echo -e "!! error merging ${repo}, skipping\n"
        failed_repos="${failed_repos} ${repo}"
        continue
    fi

    if [ "${repo}" = "spec" ]; then
        wast_dir=.
        log_and_run cp $(find repos/${repo}/test/core -name \*.wast) ${wast_dir}
    else
        wast_dir=proposals/${repo}
        mkdir -p ${wast_dir}

        # Don't add tests from proposal that are the same as spec.
        pushdir repos/${repo}
            for new in $(find test/core -name \*.wast); do
                old=../../repos/spec/${new}
                if [[ ! -f ${old} ]] || ! diff ${old} ${new} >/dev/null; then
                    log_and_run cp ${new} ../../${wast_dir}
                fi
            done
        popdir
    fi

    # Check whether any files were removed.
    for old in $(find ${wast_dir} -maxdepth 1 -name \*.wast); do
      new=$(find repos/${repo}/test/core -name ${old##*/})
      if [[ ! -f ${new} ]]; then
          log_and_run git rm ${old}
      fi
    done

    # Check whether any files were updated.
    if [ $(git status -s ${wast_dir} | wc -l) -ne 0 ]; then
        log_and_run git add ${wast_dir}/*.wast

        repo_sha=$(git -C repos/${repo} log --max-count=1 --oneline origin/${branch}| sed -e 's/ .*//')
        echo "  ${repo}:" >> commit_message
        echo "    https://github.com/WebAssembly/${repo}/commit/${repo_sha}" >> commit_message
    fi

    echo -e "-- ${repo}\n"
done

echo "" >> commit_message
echo "This change was automatically generated by \`update-testsuite.sh\`" >> commit_message
git commit -a -F commit_message
# git push

echo "done"

if [ -n "${failed_repos}" ]; then
  echo "!! failed to update repos: ${failed_repos}"
fi
