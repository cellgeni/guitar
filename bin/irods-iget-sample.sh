#!/bin/bash

set -euo pipefail

sample=$1

imeta qu -z seq -d sample = $sample and target = 1 and manual_qc = 1 \
    | perl -0777 -ne 'while (/collection:\s*(\S+)\ndataObj:\s*(\S+)/gs) { print "iget -K $1/$2\n" }' \
    | bash -e

