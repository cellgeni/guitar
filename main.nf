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
 Vladimir Kiselev @wikiselev <vk6@sanger.ac.uk>
 Stijn van Dongen @micans <svd@sanger.ac.uk>
----------------------------------------------------------------------------------------
*/

// Pipeline version
version = '0.2'

def helpMessage() {
    log.info"""
    =========================================
     rnaget pipeline v${version}
    =========================================
    Use either
      (a) --samplefile FNAME  [ --studyid ID ] [ --librarytype TYPE ] [ --manualqc off ]
      (b) --studyid ID [ --librarytype TYPE ] [ --manualqc off ]
      (c) --runid ID --lane NUM

    Studyid is queried in mlmwarehouse for sample names. Alternatively,
    samplefile FNAME should have one sample name on each line; studyid can
    still be used as samples may belong to multiple studies.

    Either (1) a list of samplenames and/or a study id from (a|b) or (2) runid
    and lane number from (c) are used to get cram files from IRODS. For (1)
    these lists can be further controlled using --librarytype TYPE and
    --manualqc off.

    Then cram files are merged and tarred.
    """.stripIndent()
}

def irodsnullvalue = "--"
params.samplefile = null
params.studyid      = irodsnullvalue
params.librarytype  = irodsnullvalue
params.manualqc     = irodsnullvalue
params.runid = null
params.lane = null
params.outdir = "results"
params.help = false


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
summary['Output dir']     = params.outdir
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
        irods.sh -r ${params.runid} -l ${params.lane} -D > ${semisample}.igetlist.txt
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
          file('*.cram') into ch_sample_cram_file

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
          .set { samplelines }
    }
    else if (params.samplefile != null) {
        sample_list = Channel.fromPath(params.samplefile)

        sample_list
          .flatMap{ it.readLines() }    // TODO: see splitText() above. unified idiom possible?
          .set { ch_samplelines }
    }

    process from_sample_lines {
        tag "${sample}"
        publishDir "${params.outdir}/cramlists"

        input:
            val sample from ch_samplelines
        output: 
            set val(sample), file('*.igetlist.txt') optional true into ch_iget_file
        script:
        """
        irods.sh -s ${sample} -t ${params.studyid} -l "${params.librarytype}" -q ${params.manualqc} -D > ${sample}.igetlist.txt
        """
    }

    ch_iget_file
      .map { tag, file -> [tag, file.readLines() ] }
      .map { tag, lines -> tuple( groupKey(tag, lines.size()), lines ) }
      .transpose()
      .set { ch_iget_item }

    process from_iget_item {
      tag "${samplename}-${igetitem}"

      maxForks 30

      input:
      set val(samplename), val(igetitem) from ch_iget_item

      output:
      set val(samplename), file('*.cram') optional true into ch_iget_merge

      script:
      """
      iget -K ${igetitem}
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
            file "${sample}.cram" into ch_sample_cram_file
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


process tar_crams {
   tag "${thecramfiles[0].baseName - '.cram'}"
   publishDir "${params.outdir}/guitar", mode: 'move'

   input:
   file thecramfiles from ch_sample_cram_file.collect()

   output:
   file '*.tar'

   script:
   """
   tar chf ${params.tartag}.tar $thecramfiles
   """
}


