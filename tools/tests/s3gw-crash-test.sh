#!/bin/bash
#
# Copyright 2023 SUSE, LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# - - -
# s3gw crash test
#
# This script will start a bunch of random object uploads in parallel to the
# s3gw and crash the s3gw at random unless the `NO_KILL` environment variable
# is set to something other than `"false"`. This will leave the backing volume
# in a dirty state with a high probability. The signal used to kill the s3gw
# can be set using the `KILL_SIGNAL` variable and is `SIGKILL` by default.

S3_HOSTNAME=${S3_HOSTNAME:-"localhost:7480"}
S3_ACCESS_KEY_ID=${S3_ACCES_KEY_ID:-"test"}
S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY:-"test"}

WORKDIR=${WORKDIR:-"${HOME}/tmp"}

KILL_SIGNAL=${KILL_SIGNAL:-"9"}
NO_KILL=${NO_KILL:-"false"}

TMPDIR=


setup() {
  [ ! -d "$WORKDIR" ] && echo "${WORKDIR} not found" && exit 1
  TMPDIR=$(mktemp -d -p "$WORKDIR" -t tmp.s3gw.XXXX)

  s3 -u create bucket

  # Pre-create 40 data blobs of random data between 50 and 150 MB in size
  # This ensures that different upload jobs will take a different amount of time
  # and increases the chances that a crash will catch out some of them in
  # different states of write.
  echo "Generating objects..."
  for i in {1..40} ; do
    size="$(( 50 + RANDOM % 100 ))"
    dd \
      if=/dev/random \
      of="${TMPDIR}/data-${i}.bin" \
      bs=1M \
      count="$size" \
      > /dev/null 2>&1
    echo "${i}/40 size ${size}"
  done
}

kill_radosgw() {
  local signal="$1"
  pid=$(pgrep radosgw)
  [ -z "${pid}" ] || kill -s "$signal" "$pid"
}

task() {
  local seq="$1"
  local id="$(( RANDOM % 40 + 1 ))"  # pick a random object to upload

  # By chance kill the gateway or if only five jobs are left to run
  if [ "$(( RANDOM % 10000 < 10 ))" = "1" ] || [ "$seq" = "995" ] ; then
    [ "$NO_KILL" = "false" ] && kill_radosgw "$KILL_SIGNAL"
    exit 1  # return failure to signal to `parallel` to terminate all jobs
  fi

  s3 -u put "bucket/obj-${seq}-${id}" < "${TMPDIR}/data-${id}.bin" > /dev/null 2>&1

  echo "object ${id} put successfully"
}

run() {
  export -f task
  export -f kill_radosgw
  export TMPDIR
  export WORKDIR
  export S3_HOSTNAME
  export S3_ACCESS_KEY_ID
  export S3_SECRET_ACCESS_KEY
  export KILL_SIGNAL
  export NO_KILL

  parallel --record-env

  for i in {1..1000} ; do echo "$i" ; done \
    | parallel --halt now,fail=1 --env _ -j 20 "task {#}"
}

cleanup() {
  echo "cleaning up..."
  rm -rf "$TMPDIR"
}

trap cleanup EXIT


setup
run
