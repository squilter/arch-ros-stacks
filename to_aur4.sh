#!/bin/sh

function usage() {
  echo "Push ROS-related package modifications to the AUR (v4)"
  echo ""
  echo "Usage 1: $0 <ROS distribution> <ROS package name>"
  echo "Example: $0 indigo desktop_full"
  echo ""
  echo "Usage 2: $0 dependency <package name>"
  echo "Example: $0 dependency python2-empy"
  echo ""
  echo "Copyright 2015 (c) Benjamin Chrétien <chretien+aur@lirmm.fr>"
  echo "Released under dual GPL license."
}


# Some PKGBUILDs were not valid when added to arch-ros-stacks (*cough*
# ros-build-tools *cough*), so our git filter-branch here will lead to invalid
# .AURINFO and a rejected push from the AUR. For now, we'll squash commits
# until the first valid one before pushing. In order to be able to update the
# AUR package with this script, DO NOT CHANGE THE COMMIT HASHES SET HERE!
function squashCheck() {
  local package=$1
  local branch=$2
  if [[ "${package}" == "ros-build-tools" ]]; then
    squashHead ${branch} c8aba9f523731dc2f7623417faf60e8a308c6a5f
  fi
}

# Function inspired from: http://stackoverflow.com/a/436530/1043187
function squashHead() {
  local branch=$1
  local good_sha=$2

  local first_sha=$(git rev-list --max-parents=0 ${branch})

  local master_branch=$(git rev-parse --abbrev-ref HEAD)

  git stash
  git checkout ${branch}

  # Go back to the last commit that we want
  # to form the initial commit (detach HEAD)
  git checkout ${good_sha}

  # reset the branch pointer to the initial commit,
  # but leaving the index and working tree intact.
  git reset --soft ${first_sha}

  # amend the initial tree using the tree from 'B'
  git commit --amend -m "Squashed commits"

  # temporarily tag this new initial commit
  # (or you could remember the new commit sha1 manually)
  git tag -f tmp

  # go back to the original branch (assume master for this example)
  git checkout ${branch}

  # Replay all the commits after B onto the new initial commit
  git rebase --no-verify --onto tmp ${good_sha}

  # remove the temporary tag
  git tag -d tmp

  git checkout ${master_branch}
  git stash pop
}

# Make sure mksrcinfo is available
command -v mksrcinfo >/dev/null 2>&1 \
  || { echo "Please install pkgbuild-introspection."; exit -1; }

set -e
set -u

# AUR4 parameters
AUR4HOST=${AUR4HOST:-aur4.archlinux.org}
AUR4USER=${AUR4USER:-aur}
AUR4PORT=${AUR4PORT:-22}

# ROS distribution
DISTRIB=${1:-}

# ROS package name (e.g. desktop_full)
LOCAL_NAME=${2:-}

if [[ -z "${DISTRIB}" || -z "${LOCAL_NAME}" ]]; then
  usage
  exit 1
fi

if [[ "${DISTRIB}" == "dependency" ]]; then
  is_ros_package="false"
elif [[ "${DISTRIB}" == "indigo" || "${DISTRIB}" == "jade" ]]; then
  is_ros_package="true"
else
  echo "ROS distribution should be \"indigo\" or \"jade\""
  exit 1
fi

# arch-ros-stacks directory
arch_ros_stacks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pushd ${arch_ros_stacks_dir}

if [[ "${is_ros_package}" == "true" ]]; then
  # Subdirectory in arch-ros-stacks
  subdir="${DISTRIB}/${LOCAL_NAME}"

  # Full AUR package name
  full_name="ros-${DISTRIB}-${LOCAL_NAME//_/-}"
else
  # Subdirectory in arch-ros-stacks
  subdir="dependencies/${LOCAL_NAME}"

  # Full AUR package name
  full_name="${LOCAL_NAME}"
fi

# Check that a PKGBUILD exists
full_pkgbuild_path="${arch_ros_stacks_dir}/${subdir}/PKGBUILD"
if [ ! -f "${full_pkgbuild_path}" ]; then
  echo "PKGBUILD not found in ${arch_ros_stacks_dir}/${subdir}"
  exit 1
fi

# Unique branch name for subtree
branch_name="aur4/${full_name}"

# Git repository in the AUR
git_repo="${AUR4USER}@${AUR4HOST}:${AUR4PORT}/${full_name}.git/"

set -x

# Check if the package already exists
if ! $(ssh -p${AUR4PORT} ${AUR4USER}@${AUR4HOST} list-repos | grep -q "${full_name}"); then
  # Create subtree and run mksrcinfo in it
  git subtree split --prefix="${subdir}" -b ${branch_name}
  squashCheck ${full_name} ${branch_name}

  git stash
  git filter-branch -f --tree-filter "mksrcinfo" -- ${branch_name}
  git stash pop

  # Setup repo if the package does not exist
  ssh -p${AUR4PORT} ${AUR4USER}@${AUR4HOST} setup-repo "${full_name}" || \
    echo "Failed to setup-repo ${full_name}... Maybe it already exists?"

  # Push subtree to AUR4
  git push "ssh+git://${git_repo}" "${branch_name}:master" || \
    echo "git push to ${full_name}.git branch master failed. Maybe repo isn't empty?"

  # Clean branch
  git branch -D ${branch_name}

# If package already exists
else
  # Fetch remote from AUR4
  git fetch "ssh+git://${git_repo}" || \
    echo "git fetch of ${full_name}.git failed. Maybe package doesn't exist?"

  # Pull from AUR4
  # FIXME: leads to merge because of remote .SRCINFO
  #git subtree pull --prefix="${subdir}" "ssh+git://${git_repo}" ${branch_name} || \
  #  echo "git pull of ${full_name}.git failed. Maybe package doesn't exist?"

  # Create subtree and run mksrcinfo in it
  git subtree split --prefix="${subdir}" -b ${branch_name}
  squashCheck ${full_name} ${branch_name}
  git stash
  git filter-branch -f --tree-filter "mksrcinfo" -- ${branch_name}
  git stash pop

  # Push to AUR4
  git push "ssh+git://${git_repo}" "${branch_name}:master" || \
    echo "git push of ${full_name}.git failed. Maybe package doesn't exist?"

  # Clean branch
  git branch -D ${branch_name}
fi

popd
