#!/bin/bash

set -euo pipefail

NULL=--         # A default absent/not-specified token so that callers can use all options set to defaults
                # e.g. irods.sh -s SAMPLE -t STUDYID -l -- -q --
                #      irods.sh -s SAMPLE -t -- -l -- -q off
                # Do not change this; calling scripts will depend on it.
sampleid=
studyid=$NULL
librarytype=$NULL
manualqc=$NULL
listobj=$NULL

while getopts :s:t:l:q:Dh opt
do
    case "$opt" in
    s)
      sampleid=$OPTARG
      ;;
    t)
      studyid=$OPTARG
      ;;
    D)
      listobj=true
      ;;
    l)
      librarytype="$OPTARG"
      ;;
    q)
      manualqc=$OPTARG
      if [[ $manualqc != "off" && $manualqc != $NULL ]]; then
        echo "Only '$NULL' and 'off' are valid options to -q option"
        false
      fi
      ;;
    h)
      cat <<EOU
Usage: irods.sh -s SAMPLENAME [-t STUDYID] [-l LIBRARYTYPE] [-q off] [-D]
=============================================================
|                                                           |
|  For -t and -l and -q you can use -- as a no-op value     |
|                                                           |
=============================================================
  -q off    remove manual_qc = 1 from imeta comand.
  -D        list database objects rather than executing iget commands
EOU
      exit
      ;;
    :) >&2 echo "Flag $opt needs argument"
        exit 1;;
    ?) >&2 echo "Flag $OPTARG unknown"
        exit 1;;
   esac
done

if [[ -z $sampleid ]]; then
  echo "I need a sample ID (-s option)"
  false
fi
if [[ $listobj == $NULL ]]; then listobj=false; fi

part_studyid=
part_librarytype=
part_manualqc=

if [[ $manualqc != "off" ]]; then
  part_manualqc="manual_qc = 1 and"
fi
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
 

