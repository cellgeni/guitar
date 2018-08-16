#!/bin/bash

                # This script implements a thin convenience layer above imeta and iget.

set -euo pipefail

NULL=--         # A default absent/not-specified token so that callers can use all options set to defaults
                # e.g. irods.sh -s SAMPLE -t STUDYID -l -- -q --
                #      irods.sh -s SAMPLE -t -- -l -- -q off
                # Do not change this; calling scripts will depend on it.
sampleid=$NULL
studyid=$NULL
librarytype=$NULL
manualqc=$NULL
runid=$NULL
laneid=$NULL

                # These options are not yet used by pipelines. If they are, they will most likely
                # benefit from using the $NULL convention sketched above.

read_obj=false     # the ',' option (used as -,) is used to signify reading IRODs object names from STDIN.
listattr=false
listobj=false

while getopts :s:t:l:q:r:y:AD,h opt       # the comma is real; -, is an option to this script
do
    case "$opt" in
    s)
      sampleid="$OPTARG"
      ;;
    ,)
      read_obj=true
      ;;
    t)
      studyid="$OPTARG"
      ;;
    D)
      listobj=true
      ;;
    A)
      listattr=true
      ;;
    y)
      librarytype="$OPTARG"
      ;;
    l)
      laneid="$OPTARG"
      ;;
    r)
      runid="$OPTARG"
      ;;
    q)
      manualqc="$OPTARG"
      if [[ $manualqc != "off" && $manualqc != $NULL ]]; then
        echo "Only '$NULL' and 'off' are valid options to -q option"
        false
      fi
      ;;
    h)
      cat <<EOU
Usage:
  irods.sh -s SAMPLENAME [ -t STUDYID | -y librarytype ] [ OPTIONS ]
  irods.sh -r RUNID -l LANEID  [ OPTIONS ]

  -t STUDYID
  -y LTYPE    library type; will be searched for as %LTYPE%
  -q off      remove manual_qc = 1 from imeta comand
  -D          list database objects rather than executing iget commands
  -A          list attributes of selected database objects
              This produces a flattened line-based format.
  -,          Read objects and list attributes. Use e.g. as

            myrods.sh -r 26425 -l 2 -D | head -n 2 | myrods.sh -r 26425 -l 2 -,

              Not needed if you use -A, but the above is useful if you only
              want to query a subset of objects.

  For -s -r -l -t -y and -q the no-op value is --. This can be useful for
  pipelines invoking this script.
EOU
      exit
      ;;
    :) >&2 echo "Flag $opt needs argument"
        exit 1;;
    ?) >&2 echo "Flag $OPTARG unknown"
        exit 1;;
   esac
done

mytag=

if [[ $runid != $NULL && $laneid != $NULL ]]; then
  mytag="$runid+$laneid"
elif [[ $sampleid != $NULL ]]; then
  mytag="$sampleid"
else
  echo "I require either -s <sample-id> or -r <run-id> -l <lane-id>" 
  false
fi

    # This part is shared by sampleid and runid+laneid
part_manualqc=
if [[ $manualqc != "off" ]]; then
  part_manualqc="manual_qc = 1 and"
fi

    #
    # The first two branches are slightly obscure, but should be self-documenting.
    # The second mode (listattr && ! listobj) indicates we were invoked with -A
    # and the caller wants attribute data for cram/object files corresponding to sample IDs.
    # In that case we first obtain the objects with -D and subsequently pipe this
    # data to irods in read_obj mode.
    #
if $read_obj; then
  >&2 echo reading object IDs and applying "'imeta ls -d ID'"
  while read d; do
    export d
    export T=$mytag
    imeta ls -d $d | perl -0777 -ne 'while (/attribute:\s*(.*?)\nvalue:\s*(.*?)\n/gs) { print "$ENV{T}\t$ENV{d}\t$1\t$2\n" }'
  done
elif $listattr && ! $listobj; then
                 #  keep these arguments, as a meaningful tag is constructed from them,
                 #  see above in the read_obj branch.
  "$0" "$@" -D | myrods.sh -, -s $sampleid -r $runid -l $laneid

elif [[ $runid != $NULL && $laneid != $NULL ]]; then
  cmd="imeta qu -z seq -d $part_manualqc id_run = $runid and lane = $laneid and target = 1"
  >&2 echo running "$cmd"
  IMETA_OUTPUT=$(eval $cmd)

  if [[ $(echo $IMETA_OUTPUT) != 'No rows found' ]]; then
    if $listobj; then
      echo "${IMETA_OUTPUT}" \
      | perl -0777 -ne 'while (/collection:\s*(\S+)\ndataObj:\s*(\S+)/gs) { print "$1/$2\n" }'
    else
      echo "${IMETA_OUTPUT}" \
      | perl -0777 -ne 'while (/collection:\s*(\S+)\ndataObj:\s*(\S+)/gs) { print "iget -K $1/$2\n" }' \
      | bash -e
    fi
  fi

elif [[ $sampleid != $NULL ]]; then
  part_studyid=
  part_librarytype=
  if [[ $studyid != $NULL ]]; then
    part_studyid="study_id = $studyid and"
  fi
  if [[ $librarytype != $NULL ]]; then
    ltype=$(printf "%q" "%$librarytype%")               # may contain spaces.
    part_librarytype="library_type like $ltype and"
  fi
    #
    # imeta command below:
    # (1) Eval is only slightly evil. We use it because the construction of
    # part_librarytype and part_studyid (and perhaps because librarytype can contain spaces).
    # Note that we escaped any spaces above using printf.
    #
    # (2) In imeta commands the most general (high-incident) query items are put first,
    # so do keep the ordering as it is now.
    # target = 1 "filters out files containing data such as spiked-in phiX and unconsented human",
    # This sounds very general, but testing says it's not, so we keep it rightmost in the imeta query.
    #
    # (3) In the presence of library_type clause, it seems faster if manual_qc is on the left.
    # in the absence of library_type clause, it seems faster if it is on the right.
    # We need to ask the DBA people for advice here.
    #
  if [[ $librarytype == $NULL ]]; then
    cmd="imeta qu -z seq -d $part_librarytype $part_studyid sample = $sampleid and $part_manualqc target = 1"
  else
    cmd="imeta qu -z seq -d $part_librarytype $part_manualqc $part_studyid sample = $sampleid and target = 1"
  fi
  >&2 echo running "$cmd"

  IMETA_OUTPUT=$(eval $cmd)

  if [[ $(echo $IMETA_OUTPUT) != 'No rows found' ]]; then
    if $listobj; then
      echo "${IMETA_OUTPUT}" \
      | perl -0777 -ne 'while (/collection:\s*(\S+)\ndataObj:\s*(\S+)/gs) { print "$1/$2\n" }'
    else
      echo "${IMETA_OUTPUT}" \
      | perl -0777 -ne 'while (/collection:\s*(\S+)\ndataObj:\s*(\S+)/gs) { print "iget -K $1/$2\n" }' \
      | bash -e
    fi
  fi
fi
   

