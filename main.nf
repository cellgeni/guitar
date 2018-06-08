#!/usr/bin/env nextflow
/*
vim: syntax=groovy
-*- mode: groovy;-*-
========================================================================================
                              R N A G E T    P I P E L I N E
========================================================================================
 #### Homepage / Documentation
 https://github.com/cellgeni/
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
      (a) --samplefile FNAME
      (b) --studyid ID
      (c) --runid ID --lane NUM
    Studyid is queried in mlmwarehouse for sample names. Alternatively,
    samplefile FNAME should have one sample name on each line.  Either (1) a
    list of samplenames from (a|b) or (2) runid and lane number from (c) are
    used to get cram files from IRODS. Then cram files are merged and tarred.
    """.stripIndent()
}

params.samplefile = null
params.studyid = null
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
    semisample = params.runid + '::' + params.lane
    process from_runid {
        output:
            set val(semisample), file('*.cram') optional true into cram_set

        script:
        """
        irods-iget-runid.sh ${params.runid} ${params.lane}
        """
    }
}

else {
    if (params.studyid != null) {
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
          .set { samplelines }
    }

    process from_sample_lines {
        tag "${sample}"
        maxForks 29

        input:
            val sample from samplelines
        output: 
            set val(sample), file('*.cram') optional true into cram_set
        script:
        """
        irods-iget-sample.sh ${sample}
        """
    }
}


process merge_from_cram_set {
    tag "${sample}"

    input: 
        set val(sample), file(crams) from cram_set
    output: 
        file "${sample}.cram" into sample_cram_file
    script:
    """
    samtools merge -f ${sample}.cram ${crams}
    """
}

process tar_crams {
   tag "${thecramfiles[0].baseName - '.cram'}"
   publishDir "${params.outdir}/guitar", mode: 'move'

   input:
   file thecramfiles from sample_cram_file.collect()

   output:
   file 'all_merged_cram.tar'

   script:
   """
   tar chf all_merged_cram.tar $thecramfiles
   """
}



