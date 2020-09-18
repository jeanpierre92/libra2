#!/bin/sh
# Copyright (c) The Libra Core Contributors
# SPDX-License-Identifier: Apache-2.0
set -e

DIR="$( cd "$( dirname "$0" )" && pwd )"

PROXY=""
if [ "$https_proxy" ]; then
	    PROXY=" --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy"
fi

# Build validator base image first
docker build -f $DIR/../validator/Dockerfile $DIR/../.. --tag libra_e2e --build-arg GIT_REV="$(git rev-parse HEAD)" --build-arg GIT_UPSTREAM="$(git merge-base HEAD origin/master)" --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" $PROXY "$@"

# Build validator_dynamic
docker build -f $DIR/Dockerfile $DIR/../.. --tag libra_validator_dynamic_perf_node0 --build-arg GIT_REV="$(git rev-parse HEAD)" --build-arg GIT_UPSTREAM="$(git merge-base HEAD origin/master)" --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" $PROXY "$@"
