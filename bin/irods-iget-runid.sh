#!/bin/bash

set -e
set -u
set -o pipefail

runid=$1
lane=$2
imeta qu -z seq -d id_run = $runid and lane = $lane and target = 1 and manual_qc = 1 |\
  perl -ne '/dataObj:\s*(.*(cram|bam))/ && print "iget -K $1\n";' | bash -e


