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

def helpMessage() {
    log.info"""
    =========================================
     rnaget pipeline v${version}
    =========================================
    Usage:
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Pipeline version
version = '0.1'

// Show help message
params.help = false
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.name = false
params.project = false
params.genome = 'GRCh38'
params.forward_stranded = false
params.reverse_stranded = false
params.unstranded = false
params.reads = 'cram/*.cram'
params.outdir = './results'
params.email = false
params.plaintext_email = false

// Define regular variables so that they can be overwritten
forward_stranded = params.forward_stranded
reverse_stranded = params.reverse_stranded
unstranded = params.unstranded

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




/*
 * Create a channel for input sample ids
 */
sample_list = Channel.fromPath('samples.txt')

process irods {
    tag "${sample}"
    
    input: 
        val sample from sample_list.flatMap{ it.readLines() }
    output: 
        set val(sample), file('*.cram') optional true into cram_files
    script:
    """
    irods.sh ${sample}
    """
}

process merge_sample_crams {
    tag "${sample}"

    publishDir "${params.outdir}/sample_cram_files", mode: 'copy'

    input: 
        set val(sample), file(crams) from cram_files
    output: 
        file "${sample}.cram" into sample_cram_file
    script:
    """
    samtools merge -f ${sample}.cram ${crams}
    """
}



