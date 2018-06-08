#!/bin/bash

set -euo pipefail

runid=$1
lane=$2

imeta qu -z seq -d id_run = $runid and lane = $lane and target = 1 and manual_qc = 1 \
    | perl -0777 -ne 'while (/collection:\s*(\S+)\ndataObj:\s*(\S+)/gs) { print "iget -K $1/$2\n" }' \
    | bash -e

