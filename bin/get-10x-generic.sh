#!/bin/bash

set -euo pipefail

sample=${1?Need sample}
libtype=${2?Need library type}
runlist=${3:-nil}

if [[ $runlist == 'nil' ]]; then
  runlist=$(myrods.sh -s $sample -D -q off  | cut -f 6 -d '/' | sort -u)
  if [[ -z $runlist ]]; then
    runlist=$(myrods.sh -s $sample -D -q off  | cut -f 3 -d '/' | sort -u)
  fi
fi


echo "sample [$sample] libtype [$libtype] runlist [$runlist]"

export PATH=$PATH:/software/npg/current/bin/:/nfs/cellgeni/tickets/tic-1065/actions/

mkdir -p $sample
cd $sample

for run in $runlist; do
  echo "$sample $run"
  nsp-cellranger-run.sh --sample $sample --id_run=$run --library_type "$libtype" --noanalysis --noarchive --noqc
done


