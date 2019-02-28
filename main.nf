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

    Publish modes: Use either one or both of
      --publish_cramtar       (default off)
      --publish_fastq         (default off)

    The output directories can be set by
      --outdir NAME           (default results)
      --outdir_cramtar NAME   (default same as --outdir)
      --outdir_fastq   NAME   (default same as --outdir)

    Select modes: Use either
 (a)  --samplefile FNAME  [ --studyid ID ] [ --librarytype TYPE ] [ --manualqc off ]
 (b)  --studyid ID [ --librarytype TYPE ] [ --manualqc off ]
 (c)  --runid ID --lane NUM

    (a) Is the primary mode and the pipeline is used in the mode very frequently.
    (b) and (c) have only seen incidental use.
    In mode (a) samplefile FNAME should have one sample name on each line; studyid should
    still be used as samples may belong to multiple studies.
    In mode (b) studyid is queried in mlmwarehouse for sample names.
    """.stripIndent()
}

def irodsnullvalue = "--"
params.samplefile = null
params.studyid      = irodsnullvalue
params.librarytype  = irodsnullvalue
params.manualqc     = irodsnullvalue
params.runid = null
params.lane = null
params.outdir          = "results"
params.outdir_cramtar  = null
params.outdir_fastq    = null
params.publish_cramtar = false
params.publish_fastq   = false
params.help = false

my = [:]
my.outdir_cramtar = params.outdir_cramtar ?: params.outdir
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


/*
 * SET UP CONFIGURATION VARIABLES
 */


// Configurable variables
params.name = false
params.tartag = "all_merged"


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


// Header log info
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


// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
nf_required_version = '0.25.0'
try {
    if( ! nextflow.version.matches(">= $nf_required_version") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}



if (params.runid != null && params.lane != null) {

    semisample = params.runid + '-' + params.lane

    process from_runid {
        output:
            file('*igetlist.txt') optional true into iget_file

        script:
        """
        irods.sh -r ${params.runid} -l ${params.lane} -q ${params.manualqc} -D > ${semisample}.igetlist.txt
        """
    }

    iget_file
      .splitText()
      .map { it.trim() }
      .set { igetlines }

    process run_iget {

        tag "${semisample}"
        maxForks 30

        input:
          val(igetspec) from igetlines

        output:
          file('*.cram') into ch_cram_tar

        script:
        """
          iget -K ${igetspec}
        """
    }
}

else {
    if (params.studyid != irodsnullvalue && params.samplefile == null) {

        process from_studyid {
            output:
                file studyid_samplefile into studyid_lines
            script:
            """
            irods-list-study.sh ${params.studyid} | tail -n +2 | cut -f 1 | sort -u > studyid_samplefile
            """
        }
        studyid_lines
          .splitText()                  // TODO: see readLines below. unified idiom possible?
          .map { it.trim() }
          .set { ch_samplelines }
    }
    else if (params.samplefile != null) {
        sample_list = Channel.fromPath(params.samplefile)

        sample_list
          .flatMap{ it.readLines() }    // TODO: see splitText() above. unified idiom possible?
          .set { ch_samplelines }
    }

    process from_sample_lines {
        tag "${sample}"
        publishDir "${params.outdir_cramtar}/cramlists"

        input:
            val sample from ch_samplelines
        output: 
            set val(sample), file('*.igetlist.txt') optional true into ch_iget_file
        script:
        """
        irods.sh -s ${sample} -t ${params.studyid} -y "${params.librarytype}" -q ${params.manualqc} -D > ${sample}.igetlist.txt
        """
    }

    ch_iget_file
      .map { tag, file -> [tag, file.readLines() ] }
      .map { tag, lines -> tuple( groupKey(tag, lines.size()), lines ) }
      .transpose()
      .set { ch_iget_item }

    process do_iget {
      tag "${samplename}-${igetitem}"

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

        input: 
            set val(sample), file(crams) from ch_cram_set
        output: 
            file "${sample}.cram" into ch_cram_tar
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


