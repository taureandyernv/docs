#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025, NVIDIA CORPORATION & AFFILIATES.
# All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Copies the RAPIDS libraries' HTML files from S3 into the "_site" directory of
# the Jekyll build.
set -euo pipefail

export JEKYLL_DIR="_site"

export GENERATED_DIRS="
libs: ${JEKYLL_DIR}/api
deployment: ${JEKYLL_DIR}/deployment
"
export DOCS_BUCKET="rapidsai-docs"

# Checks that the "_site" directory exists from a Jekyll build. Also ensures
# that the directories that are pulled from S3 aren't already present in the
# "_site" directory since that could cause problems.
check_dirs() {
  local DIR API_DIR

  if [ ! -d "${JEKYLL_DIR}" ]; then
    echo "\"${JEKYLL_DIR}\" directory does not exist."
    echo "Build Jekyll site first."
    exit 1
  fi


  API_DIR=$(yq -n 'env(GENERATED_DIRS) | .libs')
  if [[ $(cd "${API_DIR}"; ls -1d ./*) != "./index.html" ]]; then
    echo "The \"${API_DIR}\" directory should only contain a single 'index.html' file."
    exit 1
  fi

  for DIR in $(yq -n 'env(GENERATED_DIRS) | del .libs | .[]'); do
    if [ -d "${DIR}" ]; then
      echo "The \"${DIR}\" directory is populated at deploy time and should not already exist."
      echo "Ensure the \"${DIR}\" directory is not generated by Jekyll."
      exit 1
    fi
  done
}

# Helper function for the `aws cp` command. Checks to ensure that the source
# directory has contents before attempting the copy.
aws_cp() {
  local SRC DST

  SRC=$1
  DST=$2

  if ! aws s3 ls "${SRC}" > /dev/null; then
    echo "No files found in ${SRC}. Exiting."
    exit 1
  fi

  echo "Copying ${SRC} to ${DST}"
  aws s3 cp \
    --only-show-errors \
    --recursive \
    "${SRC}" \
    "${DST}"
}

# Downloads the RAPIDS libraries' documentation files from S3 and places them
# into the "_site/api" folder. The versions that should be copied are read from
# "_data/releases.json" and the libraries that should be copied are read from
# "_data/docs.yml".
download_lib_docs() {
  local DST PROJECT PROJECT_MAP \
        SRC VERSION_MAP VERSION_NAME \
        VERSION_NUMBER

  VERSION_MAP=$(jq '{
    "legacy": { "version": .legacy.version, "ucxx_version": .legacy.ucxx_version },
    "stable": { "version": .stable.version, "ucxx_version": .stable.ucxx_version },
    "nightly": { "version": .nightly.version, "ucxx_version": .nightly.ucxx_version }
  }' _data/releases.json)

  PROJECT_MAP=$(yq '.apis + .libs' _data/docs.yml)

  for VERSION_NAME in $(jq -r 'keys | .[]' <<< "$VERSION_MAP"); do
    for PROJECT in $(yq -r 'keys | .[]' <<< "$PROJECT_MAP"); do
      VERSION_NUMBER=$(jq -r --arg vn "$VERSION_NAME" --arg pr "$PROJECT" '
        if ($pr | contains("ucxx")) then
          .[$vn].ucxx_version
        else
          .[$vn].version
        end' <<< "$VERSION_MAP")

      PROJECT_MAP_JSON=$(yq -r -o json '.' <<< "$PROJECT_MAP")
      if [ "$(jq -r --arg pr "$PROJECT" --arg vn "$VERSION_NAME" '.[$pr].versions[$vn]' <<< "$PROJECT_MAP_JSON")" == "0" ]; then
        echo "Skipping: $PROJECT | $VERSION_NAME | $VERSION_NUMBER"
        continue
      fi

      SRC="s3://${DOCS_BUCKET}/${PROJECT}/html/${VERSION_NUMBER}/"
      DST="$(yq -n 'env(GENERATED_DIRS)|.libs')/${PROJECT}/${VERSION_NUMBER}/"

      aws_cp "${SRC}" "${DST}"
    done
  done
}

# Downloads the deployment docs from S3 and places them in the
# "_site/deployment" directory.
download_deployment_docs() {
  local DST SRC VERSION

  for VERSION in nightly stable; do
    SRC="s3://${DOCS_BUCKET}/deployment/html/${VERSION}/"
    DST="$(yq -n 'env(GENERATED_DIRS)|.deployment')/${VERSION}/"

    aws_cp "${SRC}" "${DST}"
  done
}

check_dirs
download_lib_docs
download_deployment_docs
