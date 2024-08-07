#!/bin/bash

source .buildkite/scripts/common.sh

set -euo pipefail

add_bin_path
with_yq

pushd packages > /dev/null
PACKAGE_LIST=$(list_all_directories)
popd > /dev/null

PIPELINE_FILE="packages_pipeline.yml"
touch packages_pipeline.yml

cat <<EOF > ${PIPELINE_FILE}
steps:
  - group: ":terminal: Test integrations"
    key: "integration-tests"
    steps:
EOF

# Get from and to changesets to avoid repeating the same queries for each package

# setting range of changesets to check differences
from="$(get_from_changeset)"
to="$(get_to_changeset)"

echo "[DEBUG] Checking with commits: from: '${from}' to: '${to}'"

packages_to_test=0

for package in ${PACKAGE_LIST}; do
    # Check if the package name begins with "aws"
    if [[ "${package}" != aws_bedrock* && "${package}" != influx* ]]; then
        continue
    fi
    # if [[ "${package}" != aws_bedrock* && "${package}" != oracle* && "${package}" != influx* ]]; then
    #     continue
    # fi
    # check if needed to create an step for this package
    pushd "packages/${package}" > /dev/null
    skip_package="false"
    if ! reason=$(is_pr_affected "${package}" "${from}" "${to}") ; then
        skip_package="true"
    fi
    echoerr "${reason}"
    popd > /dev/null

    if [[ "$skip_package" == "true" ]] ; then
        continue
    fi

    packages_to_test=$((packages_to_test+1))
    cat << EOF >> ${PIPELINE_FILE}
    - label: "Check integrations ${package}"
      key: "test-integrations-${package}"
      command: |
        cd integrations
        .buildkite/scripts/test_one_package.sh ${package} ${from} ${to}
        cd ../integrations-e2e-tests/buildkite/scripts
        python3 integrationpkg_populate_integration_junit_to_es.py
        
      env:
        STACK_VERSION: "${STACK_VERSION}"
        FORCE_CHECK_ALL: "${FORCE_CHECK_ALL}"
        SERVERLESS: "false"
        UPLOAD_SAFE_LOGS: ${UPLOAD_SAFE_LOGS}
        AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
        AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
        ELASTICSEARCH_ENDPOINT: ${ELASTICSEARCH_ENDPOINT}
        ELASTIC_CLOUD_ID: ${ELASTIC_CLOUD_ID}
        ELASTICSEARCH_API_KEY: ${ELASTICSEARCH_API_KEY}
        BUILDKITE_BUILD_CHECKOUT_PATH: "/var/lib/buildkite-agent/e2e_integrations_individual"
        INTEGRATION_PKGS_JUNIT_ARTIFACT_PATH: "/var/lib/buildkite-agent/e2e_integrations_individual/integrations/build/test-results/"
        ELASTICSEARCH_INDEX_INTEGRATION_PKGS_JUNIT_SYSTEMTEST: "integration_pkgs_junit_systemtest"
        
        
      plugins:
      - hasura/smooth-checkout#v4.4.1:
          delete_checkout: true
          repos:
            - config:
              - url: git@github.com:agikthomas/integrations.git
            - config:
              - url: git@github.com:agithomas/integrations-e2e-tests.git
                ssh_key_path: /var/lib/buildkite-agent/.ssh/id_ed25519
      artifact_paths:
        - integrations/build/test-results/*.xml
        - integrations/build/test-coverage/*.xml
        - integrations/build/benchmark-results/*.json
        - integrations/build/elastic-stack-dump/*/logs/*.log
        - integrations/build/elastic-stack-dump/*/logs/fleet-server-internal/**/*
EOF
done

if [ ${packages_to_test} -eq 0 ]; then
    buildkite-agent annotate "No packages to be tested" --context "ctx-no-packages" --style "warning"
    exit 0
fi

cat ${PIPELINE_FILE} | buildkite-agent pipeline upload
