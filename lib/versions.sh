#!/usr/bin/env bash

if type dep &>/dev/null ; then
    dep include log2/shell-common:0.2.0 log
else
    include log2/shell-common lib/log.sh
fi

req jq xmlstarlet yq

project_version() {
    local vFileBasic="version"
    local vFileMaven="pom.xml"
    local vFileGradle="app/versions.gradle"
    local vFileAngular="package.json"
    local vFileHelm="chart/Chart.yaml"

    local baseDir=${1:-.}
    log "searching version file in path: $baseDir"

    local vFileBasicPath="$baseDir/$vFileBasic"
    local vFileMavenPath="$baseDir/$vFileMaven"
    local vFileGradlePath="$baseDir/$vFileGradle"
    local vFileAngularPath="$baseDir/$vFileAngular"
    local vFileHelmPath="$baseDir/$vFileHelm"

    local vFiles=""
    local version=""
    local count=0
    if [ -f "$vFileBasicPath" ]; then
        vFiles="$vFiles'$vFileBasic'"
        version=$(cat "$vFileBasicPath")
        ((count++))
    fi
    if [ -f "$vFileMavenPath" ]; then
        vFiles="$vFiles'$vFileMaven'"
        version=$(xmlstarlet sel -N x=http://maven.apache.org/POM/4.0.0 -t -m "/x:project/x:version" -v . "$vFileMavenPath")
        ((count++))
    fi
    if [ -f "$vFileGradlePath" ]; then
        vFiles="$vFiles'$vFileGradle'"
        version=$(grep "commonVersion" "$vFileGradlePath" | sed 's/.*"\(.*\)".*/\1/')
        ((count++))
    fi
    if [ -f "$vFileAngularPath" ]; then
        vFiles="$vFiles'$vFileAngular'"
        version=$(jq -r '.version'<"$vFileAngularPath")
        ((count++))
    fi
    if [ -f "$vFileHelmPath" ]; then
        vFiles="$vFiles'$vFileHelm'"
        version=$(yq r - "version"<"$vFileHelmPath")
        ((count++))
    fi
    if [ "$count" = 0 ]; then
        whine "no version file found"
    elif [ "$count" -gt 1 ]; then
        whine "too much ($count) version files found: $vFiles"
    fi
    log "found version='$version' in file: $vFiles"
    echo "$version"
}

add_version_qualifier() {
    local version="$1"
    local qualifier="$2"
    if [[ "$version" = *"-SNAPSHOT" ]] ; then 
        baseVersion=${version%-SNAPSHOT}
        echo "$baseVersion-$qualifier-SNAPSHOT"
    else
        echo "$version-$qualifier"
    fi
}

add_snapshot_id() {
    local version="$1"
    local baseDir=${2:-.}
    if [[ "$version" = *"-SNAPSHOT" ]] ; then 
        commitId=$(git_commit)
        echo "$version-$commitId"
    else
        echo "$version"
    fi
}

git_commit() {
    local baseDir=${1:-.}
    commitId=$(cd "$baseDir" && git rev-parse HEAD)
    echo "$commitId"
}

git_branch() {
    local baseDir=${1:-.}
    commitId=$(git_commit "$baseDir")
    local branch
    branch=$(cd "$baseDir" && git rev-parse --abbrev-ref HEAD)
    if [[ "$branch" = "HEAD" ]] ; then
        #FIXME possible problems if more than one branch found
        branch=$(cd "$baseDir" && git for-each-ref --format='%(objectname) %(refname:short)' refs | awk "/^$commitId/ {print \$2}")
        branch=${branch##origin/}
    fi
    echo "$branch"
}

git_current_tag() {
    local baseDir=${1:-.}
    git_tag=$(cd "$baseDir" && git describe --exact-match --tags)
    echo "$git_tag"
}

git_tag_exists() {
    local baseDir=$1
    local tag=$2
    (cd "$baseDir" && git tag | grep "^$tag$" 1>&2 )
}

get_patch_number() {
    version=$1
    echo "${version##*.}"
}

check_version() {
    baseDir=${1:-.}
    version=$(project_version "$baseDir") || exit 1
    baseVersion=${version%%-*}
    branch=$(git_branch "$baseDir")

    unset isSnapshot
    if [[ $version == *"-SNAPSHOT" ]]; then
        isSnapshot=true
    fi
    unset isRC
    if [[ $baseVersion =~ .*-rc[1-9]?[0-9]* ]]; then
        isRC=true
    fi

    patchNumber=$(get_patch_number "$baseVersion")
    log "checking version $version (baseVersion:$baseVersion, isSnapshot:${isSnapshot:-false}, isRC:${isRC:-false}, patchNumber:$patchNumber) in branch $branch"

    check_tag() {
        if git_tag_exists "$baseDir" "$version" ; then
            whine "tag $version already found"
        fi
    }

    check_master() {
        [[ -z $isSnapshot ]] || whine "SNAPSHOT version not allowed"
        [[ -z $isRC ]] || whine "rc version not allowed"
        check_tag
    }

    check_develop() {
        [[ -n $isSnapshot ]] || whine "non SNAPSHOT version not allowed"
        [[ -z $isRC ]] || whine "rc version not allowed"
        [[ $patchNumber == 0 ]] || whine "non-zero patch version not allowed"
    }

    check_release() {
        [[ -n $isRC ]] || whine "non rc version not allowed"
        [[ $patchNumber == 0 ]] || whine "non-zero patch version not allowed"
        if [[ -z $isSnapshot ]] ; then
            check_tag
        fi
    }

    case "$branch" in
        "master" | "main")
            check_master
            ;;
        "develop" | "feature/"*)
            check_develop
            ;;
        "release/"*)
            check_release
            ;;
        *)
            whine "unsupported branch $branch"
    esac

    echo "$version"
}

create_version_tag() {
    local baseDir=${1:-.}
    local version
    version=$(project_version "$baseDir")
    (
        cd "$baseDir" || exit 1
        if [ -z "$(git status --porcelain)" ]; then 
            git tag "$version"
            log "added tag: $version"
        else
            whine "uncommitted changes found"
        fi
    )    
}
