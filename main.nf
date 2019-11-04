#!/usr/bin/env nextflow
/*
vim: syntax=groovy
-*- mode: groovy;-*-
========================================================================================
                              R N A G E T    P I P E L I N E
========================================================================================
 #### Homepage / Documentation
 https://github.com/cellgeni/guitar
 #### Authors
 Stijn van Dongen @micans <svd@sanger.ac.uk>
 Vladimir Kiselev @wikiselev <vk6@sanger.ac.uk>
*/

// Pipeline version
version = '0.3'

def helpMessage() {
    log.info"""
    =========================================
     rnaget pipeline v${version}
    =========================================
    This pipeline pulls samples from IRODS based on a list of sample IDs and a study ID.
    The samples can be published as fastq files for consumption by analysis pipelines (use --publish_fastq),
    and/or can be published as a tar archive of cram files for data sharing (use --publish_cramtar).

    For off/on options, use
      --option false          (turn off)
      --option true           (turn on)
      --option                (turn on)

    Publish modes: Use either one or more of
      --publish_cramtar       (default off)
      --publish_fastq         (default off)
      --publish_crams         (default off)

    The output directories can be set by
      --outdir NAME           (default results)
      --outdir_cramtar NAME   (default same as --outdir)
      --outdir_crams   NAME   (default same as --outdir)
      --outdir_fastq   NAME   (default same as --outdir)

    Select modes: Use either
 (a)  --samplefile FNAME  [ --studyid ID ] [ --librarytype TYPE ] [ --manualqc off ]
 (b)  --studyid ID [ --librarytype TYPE ] [ --manualqc off ]
 (c)  --runid ID --lane NUM
 (d)  --samplefile10x FNAME [ --outdir_fastq | --outdir ]

    (a) Is the primary mode and the pipeline is used in the mode very frequently.
    (b) and (c) have only seen incidental use.
    In mode (a) samplefile FNAME should have one sample name on each line; studyid should
    still be used as samples may belong to multiple studies.
    In mode (b) studyid is queried in mlmwarehouse for sample names.
    """.stripIndent()
}

def irodsnullvalue = "--"
params.samplefile = null
params.samplefile10x = null
params.studyid      = irodsnullvalue
params.librarytype  = irodsnullvalue
params.manualqc     = irodsnullvalue
params.runid = null
params.lane = null
params.outdir          = "results"
params.outdir_cramtar  = null
params.outdir_crams    = null
params.outdir_fastq    = null
params.publish_cramtar = false
params.publish_fastq   = false
params.publish_crams   = false
params.help = false
params.tartag = "all_merged"

my = [:]
my.outdir_cramtar = params.outdir_cramtar ?: params.outdir
my.outdir_crams   = params.outdir_crams   ?: params.outdir
my.outdir_fastq   = params.outdir_fastq   ?: params.outdir


if (params.help) {
  helpMessage()
  exit 0
}


if ((params.runid != null && params.lane != null) || params.samplefile || params.studyid) {
}
else {
  helpMessage()
  exit 1
}



log.info "========================================="
log.info "         rnaget pipeline v${version}"
log.info "========================================="
def summary = [:]
summary['Max Memory']     = params.max_memory
summary['Max CPUs']       = params.max_cpus
summary['Max Time']       = params.max_time
summary['Output dir (cramtar)']  = my.outdir_cramtar
summary['Output dir (fastq)']    = my.outdir_fastq
summary['Working dir']    = workflow.workDir
summary['Current home']   = "$HOME"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="



/*
  This code looks more complicated than it is. Some reasons:

  - Three input modes: (a) samplefile + studyid (b) studyid (c) runID+laneNUM
  - iget is parallelised, i.e. if a cram file consists of multiple files in IRODs.

*/


process from_runid {

    memory 1.GB

    when: params.runid != null && params.lane != null
      
    output:
        file('*igetlist.txt') optional true into ch_igetfile_fromrunid

    script:
    semisample = params.runid + '-' + params.lane
    """
    irods.sh -r ${params.runid} -l ${params.lane} -q ${params.manualqc} -D > ${semisample}.igetlist.txt
    """
}

ch_igetfile_fromrunid
  .splitText()
  .map { it.trim() }
  .set { ch_tagindex }

process run_iget {

    memory 1.GB
    maxForks 20

    input:
      val(igetspec) from ch_tagindex

    output:
      file('*.cram') into ch_cram_tar_fromrunlane

    script:
    """
      iget -K ${igetspec}
    """
}


ch_sample_list    = params.samplefile    != null? Channel.fromPath(params.samplefile)    : Channel.empty()
ch_sample_list10x = params.samplefile10x != null? Channel.fromPath(params.samplefile10x) : Channel.empty()

ch_sample_list
  .flatMap{ it.readLines() }
  .set { ch_samplelines_sf }

ch_sample_list10x
  .flatMap{ it.readLines() }
  .set { ch_samplelines_10x }

process from_studyid {

    memory 1.GB

    when: params.studyid != irodsnullvalue && params.samplefile == null

    output:
        file studyid_samplefile into ch_studyid_lines
    script:
    """
    irods-list-study.sh ${params.studyid} | tail -n +2 | cut -f 1 | sort -u > studyid_samplefile
    """
}

ch_studyid_lines
  .splitText()
  .map { it.trim() }
  .set { ch_samplelines_studyid }


ch_samplelines_sf.mix(ch_samplelines_studyid)
  .set { ch_samplelines }



process from_sample_lines {

    memory 1.GB
    maxForks 30

    tag "${sample}"
    publishDir "${my.outdir_cramtar}/cramlists"

    input:
        val sample from ch_samplelines
    output: 
        set val(sample), file('*.igetlist.txt') optional true into ch_igetfile_fromsample
    script:
    """
    irods.sh -s ${sample} -t ${params.studyid} -y "${params.librarytype}" -q ${params.manualqc} -D > ${sample}.igetlist.txt
    """
}


process from_sample_lines10x {

    tag "${sample}"

    publishDir "${my.outdir_fastq}", mode: 'link'

    input:
        val sample from ch_samplelines_10x
    output: 
        file '*.tar'
        file '*.counts'
    shell:
    '''
    npg_10x_fastq --sample !{sample} --cores !{task.cpus}
    nfiles=$(ls */*.fastq.gz | wc -l)
    echo -e "!{sample}\t$nfiles" >> !{sample}.counts
    if (( $nfiles > 0 )); then
      tar cf !{sample}.tar --transform='s/.*\\///' */*.fastq.gz
    fi
    '''
}


ch_igetfile_fromsample
  .map { tag, file -> [tag, file.readLines() ] }
  .map { tag, lines -> tuple( groupKey(tag, lines.size()), lines ) }
  .transpose()
  .set { ch_iget_item }


process do_iget {
  tag "${samplename}-${igetitem}"

  // Memory and cpus set in base.config
  maxForks 30

  input:
  set val(samplename), val(igetitem) from ch_iget_item

  output:
  set val(samplename), file('*.cram') optional true into ch_iget_merge

  script:
  """
  iget -N ${task.cpus} -K ${igetitem}
  """
}


ch_iget_merge
  .groupTuple()
  .set { ch_cram_set }


process merge_from_cram_set {
    tag "${sample}"

    // Memory and cpus set in base.config

    input: 
    set val(sample), file(crams) from ch_cram_set

    output: 
    file "${sample}.cram" into ch_cram_tar_fromids
    set val(sample), file("${sample}.cram") into ch_fastq_publish

    script:
    cram0 = crams[0]
    """
    num=\$(for f in ${crams}; do echo \$f; done | grep -c ".cram\$");
    if [[ \$num == 1 ]]; then
        ln -s "${cram0}" ${sample}.cram
    else
        if ! samtools cat -o ${sample}.cram ${crams}; then
            samtools merge -@ ${task.cpus} -f ${sample}.cram ${crams}
        fi
    fi
    """
}


ch_cram_tar_fromrunlane.mix(ch_cram_tar_fromids)
  .into { ch_cram_tar; ch_publish_cram }

ch_publish_cram
  .until{ !params.publish_crams }
  .subscribe {
      it.copyTo("${my.outdir_crams}/")
  }


process crams_to_fastq {
    tag "${sample}"
    publishDir "${my.outdir_fastq}", mode: 'link'

    when:
        params.publish_fastq

    input:
        set val(sample), file(cramfile) from ch_fastq_publish

    output:
        file("${sample}_?.fastq.gz")
        file("${sample}.numreads.txt")

    shell:
        // 0.7 factor below: see https://github.com/samtools/samtools/issues/494
        // This is not confirmed entirely just yet.
        // def avail_mem = task.memory == null ? '' : "${ sprintf "%.0f", 0.7 * ( task.memory.toBytes() - 2000000000 ) / task.cpus}"
    '''
    f1=!{sample}_1.fastq.gz
    f2=!{sample}_2.fastq.gz

    numreads=$(samtools view -c -F 0x900 !{cramfile})
    echo $numreads > !{sample}.numreads.txt
                              # -O {stdout} -u {no compression}
                              # -N {always append /1 and /2 to the read name}
                              # -F 0x900 (bit 1, 8, filter secondary and supplementary reads)
    samtools collate    \\
        -O -u           \\
        -@ !{task.cpus} \\
        !{cramfile} pfx-!{sample} | \\
    samtools fastq      \\
        -N              \\
        -F 0x900        \\
        -@ !{task.cpus} \\
        -1 $f1 -2 $f2 \\
        -
    '''
}


process tar_crams {
   tag "${thecramfiles[0].baseName - '.cram'}"
   publishDir "${my.outdir_cramtar}", mode: 'move'

   when:
     params.publish_cramtar

   input:
     file thecramfiles from ch_cram_tar.collect()

   output:
     set file('*.tar'), file('*.md5')

   script:
   def tf = "${params.tartag}.tar"
   def m5 = "${params.tartag}.md5"
   """
   tar chf $tf $thecramfiles
   md5sum $tf > $m5
   """
}


