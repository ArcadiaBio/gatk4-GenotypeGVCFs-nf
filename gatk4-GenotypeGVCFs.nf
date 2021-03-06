#!/usr/bin/env nextflow

// Copyright (C) 2018 IARC/WHO

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

params.help = null

log.info ""
log.info "-------------------------------------------------------------------------"
log.info "  gatk4-GenotypeGVCFs v1: Exact Joint Genotyping GATK4 Best Practices         "
log.info "-------------------------------------------------------------------------"
log.info "Copyright (C) IARC/WHO"
log.info "This program comes with ABSOLUTELY NO WARRANTY; for details see LICENSE"
log.info "This is free software, and you are welcome to redistribute it"
log.info "under certain conditions; see LICENSE for details."
log.info "-------------------------------------------------------------------------"
log.info ""

if (params.help)
{
    log.info "---------------------------------------------------------------------"
    log.info "  USAGE                                                 "
    log.info "---------------------------------------------------------------------"
    log.info ""
    log.info "nextflow run iarcbioinfo/gatk4-GenotypeGVCFs-nf [OPTIONS]"
    log.info ""
    log.info "Mandatory arguments:"
    log.info "--input                         VCF FILES                 All cohort gVCF files (between quotes)"
    log.info "--output_dir                    OUTPUT FOLDER             Output for VCF file"
    log.info "--cohort                        STRING                    Cohort name"
    log.info "--ref_fasta                     FASTA FILE                Reference FASTA file"
    log.info "--gatk_exec                     BIN PATH                  Full path to GATK4 executable"
    log.info "--dbsnp                         VCF FILE                  dbSNP VCF file"
    log.info "--mills                         VCF FILE                  Mills and 1000G gold standard indels VCF file"
    log.info "--axiom                         VCF FILE                  Axiom Exome Plus genotypes all populations poly VCF file"
    log.info "--hapmap                        VCF FILE                  hapmap VCF file"
    log.info "--omni                          VCF FILE                  1000G omni VCF file"
    log.info "--onekg                         VCF FILE                  1000G phase1 snps high confidence VCF file"
    exit 1
}

//
// Parameters Init
//
params.input         = null
params.output_dir    = "."
params.cohort        = "cohort"
params.ref_fasta     = null
params.gatk_exec     = null
params.dbsnp         = null
params.mills         = null
params.axiom         = null
params.hapmap        = null
params.omni          = null
params.onekg         = null

//
// Parse Input Parameters
//
gvcf_ch = Channel
			.fromPath(params.input)

gvcf_idx_ch = Channel
			.fromPath(params.input)
			.map { file -> file+".idx" }

			
GATK                              = params.gatk_exec
ref                               = file(params.ref_fasta)
//dbsnp_resource_vcf                = file(params.dbsnp)
//mills_resource_vcf                = file(params.mills)
//axiomPoly_resource_vcf            = file(params.axiom)
//hapmap_resource_vcf               = file(params.hapmap)
//omni_resource_vcf                 = file(params.omni)
//one_thousand_genomes_resource_vcf = file(params.onekg)

// ExcessHet is a phred-scaled p-value. We want a cutoff of anything more extreme
// than a z-score of -4.5 which is a p-value of 3.4e-06, which phred-scaled is 54.69
excess_het_threshold = 54.69

// Store the chromosomes in a channel for easier workload scattering on large cohort
//chromosomes_ch = Channel
//    .from( "chr1", "chr2", "chr3", "chr4", "chr5", "chr6", "chr7", "chr8", "chr9", "chr10", "chr11", "chr12", "chr13", "chr14", "chr15", "chr16", "chr17", "chr18", "chr19", "chr20", "chr21", "chr22", "chrX", "chrY" )

chromosomes_ch = Channel.fromPath("${params.ref_fai}")
  .splitCsv(header: false, sep: '\t')
  .map {row -> row[0]}


//
// Process launching GenomicsDBImport to gather all VCFs, per chromosome
//
process GenomicsDBImport {

	cpus 1 

    time { (10.hour + (2.hour * task.attempt)) } // First attempt 12h, second 14h, etc
    memory { (64.GB + (8.GB * task.attempt)) } // First attempt 72GB, second 80GB, etc

    errorStrategy 'retry'
    maxRetries 3

	tag { chr }

    input:
	each chr from chromosomes_ch
    file (gvcf) from gvcf_ch.collect()
	file (gvcf_idx) from gvcf_idx_ch.collect()

	output:
    set chr, file ("${params.cohort}.${chr}") into gendb_ch
	
    script:
	"""
	${GATK} GenomicsDBImport --java-options "-Xmx24g -Xms24g -Djava.io.tmpdir=/tmp" \
	${gvcf.collect { "-V $it " }.join()} \
    -L ${chr} \
    --batch-size 50 \
    --genomicsdb-workspace-path ${params.cohort}.${chr}
	
	"""
}	


//
// Process launching GenotypeGVCFs on the previously created genDB, per chromosome
//
process GenotypeGVCFs {

	cpus 4 
	memory '48 GB'
	time '20h'
	
	tag { chr }

	publishDir params.output_dir, mode: 'copy', pattern: '*.{vcf,idx}'

    input:
	set chr, file (workspace) from gendb_ch
   	file genome from ref

	output:
    set chr, file("${params.cohort}.${chr}.vcf"), file("${params.cohort}.${chr}.vcf.idx") into vcf_ch
    file "${genome}.fai" into faidx_sid_ch,faidx_snv_ch
	file "${genome.baseName}.dict" into dict_sid_ch,dict_snv_ch

    script:
	"""
    samtools faidx ${genome}

    java -jar ${params.picard_dir}/picard.jar \
    CreateSequenceDictionary \
    R=${genome} \
    O=${genome.baseName}.dict

    WORKSPACE=\$( basename ${workspace} )

    ${GATK} --java-options "-Xmx5g -Xms5g" \
     GenotypeGVCFs \
     -R ${genome} \
     -O ${params.cohort}.${chr}.vcf \
     -G StandardAnnotation \
     --include-non-variant-sites \
     --only-output-calls-starting-in-intervals \
     -V gendb://\$WORKSPACE \
     -L ${chr}

	"""
}	


//
// Process Hard Filtering on ExcessHet, per chromosome
//
process HardFilter {

	cpus 1
	memory '24 GB'
	time '12h'
	
	tag { chr }

    input:
	set chr, file (vcf), file (vcfidx) from vcf_ch

	output:
    file("${params.cohort}.${chr}.filtered.vcf") into (vcf_hf_ch)
    file("${params.cohort}.${chr}.filtered.vcf.idx") into (vcf_idx_hf_ch)

    script:
	"""
	${GATK} --java-options "-Xmx3g -Xms3g" \
      VariantFiltration \
      --filter-expression "ExcessHet > ${excess_het_threshold}" \
      --filter-name ExcessHet \
      -V ${vcf} \
      -O ${params.cohort}.${chr}.markfiltered.vcf

	${GATK} --java-options "-Xmx3g -Xms3g" \
      SelectVariants \
      --exclude-filtered \
      -V ${params.cohort}.${chr}.markfiltered.vcf \
      -O ${params.cohort}.${chr}.filtered.vcf

	"""
}	


chromosomes_ch2 = Channel.fromPath("${params.ref_fai}")
  .splitCsv(header: false, sep: '\t')
  .map {row -> 
  chrom = row[0]
  chrom.tokenize('.')[0]
  }.toList()

process GatherVcfs {

	publishDir params.output_dir, mode: 'copy', pattern: '*.{vcf,idx}'

	cpus 1
	memory '48 GB'
	time '12h'
	
	tag "${params.cohort}"

    input:
      val(chrom_list) from chromosomes_ch2
      file (vcf) from vcf_hf_ch.collect()
	file (vcf_idx) from vcf_idx_hf_ch.collect()

	output:
    set file("${params.cohort}.vcf"), file("${params.cohort}.vcf.idx") into (vcf_snv_ch, vcf_sid_ch, vcf_recal_ch)

    // WARNING : complicated channel extraction! 
    // GATK GatherVcfs only accepts as input VCF in the chromosomical order. Nextflow/Groovy list are not sorted. The following command does :
    // 1 : look for all VCF with "chr[0-9]*" in the filename (\d+ means 1 or + digits)
    // 2 : Tokenize the filenames with "." as the separator, keep the 2nd item (indexed [1]) "chr[0-9]*"
    // 3 : Take from the 3rd character till the end of the string "chr[0-9]*", ie the chromosome number
    // 4 : Cast it from a string to an integer (to force a numerical sort)
    // 5 : Sort 
    // 6 : Add chrX and chrY to the list

    script:
	
	vcf_sorted = vcf.collect().sort{ chrom_list.indexOf(it.baseName.tokenize('.')[1])}.join(" --INPUT " )
	
	"""
	${GATK} --java-options "-Xmx3g -Xms3g" \
      GatherVcfs \
      --INPUT ${vcf_sorted} \
      --OUTPUT ${params.cohort}.vcf
	"""
}	



//
// Process SID recalibration
//
process SID_VariantRecalibrator {

	cpus 1
	memory '24 GB'
	time '12h'
	
	tag "${params.cohort}"

    input:
	set file (vcf), file (vcfidx) from vcf_sid_ch
    file genome from ref
    file faidx from faidx_sid_ch
    file dict from dict_sid_ch

	output:
    set file("${params.cohort}.sid.recal"),file("${params.cohort}.sid.recal.idx"),file("${params.cohort}.sid.tranches") into sid_recal_ch

    script:
	"""
    ${GATK} --java-options "-Xmx24g -Xms24g" \
      VariantRecalibrator \
      -R ${genome} \
      -V ${vcf} \
      --output ${params.cohort}.sid.recal \
      --tranches-file ${params.cohort}.sid.tranches \
      --trust-all-polymorphic \
      -an QD -an DP -an FS -an SOR -an ReadPosRankSum -an MQRankSum -an InbreedingCoeff \
      -mode INDEL \
      --max-gaussians 4
      
	"""
}	



//
// Process SNV recalibration
//
process SNV_VariantRecalibrator {

	cpus 1
	memory '90 GB'
	time '12h'
	
	tag "${params.cohort}"

    input:
	set file (vcf), file (vcfidx) from vcf_snv_ch
    file genome from ref
    file faidx from faidx_snv_ch
    file dict from dict_snv_ch

	output:
    set file("${params.cohort}.snv.recal"),file("${params.cohort}.snv.recal.idx"),file("${params.cohort}.snv.tranches") into snv_recal_ch

    script:
	"""
    ${GATK} --java-options "-Xmx90g -Xms90g" \
      VariantRecalibrator \
      -R ${genome} \
      -V ${vcf} \
      --output ${params.cohort}.snv.recal \
      --tranches-file ${params.cohort}.snv.tranches \
      --trust-all-polymorphic \
      -an QD -an MQ -an MQRankSum -an ReadPosRankSum -an FS -an SOR -an DP -an InbreedingCoeff \
      -mode SNP \
      --max-gaussians 6
      
	"""
}	



//
// Process Apply SNV and SID recalibrations
//
process ApplyRecalibration {

	cpus 1 
	memory '7 GB'
	time '12h'
	
	tag "${params.cohort}"

	publishDir params.output_dir, mode: 'copy'

    input:
	set file (input_vcf), file (input_vcf_idx) from vcf_recal_ch
	set file (indels_recalibration), file (indels_recalibration_idx), file (indels_tranches) from sid_recal_ch
	set file (snps_recalibration), file (snps_recalibration_idx), file (snps_tranches) from snv_recal_ch

	output:
    set file("${params.cohort}.recalibrated.vcf"),file("${params.cohort}.recalibrated.vcf.idx") into vcf_final_ch

    script:
	"""
    ${GATK} --java-options "-Xmx5g -Xms5g" \
      ApplyVQSR \
      -O tmp.indel.recalibrated.vcf \
      -V ${input_vcf} \
      --recal-file ${indels_recalibration} \
      --tranches-file ${indels_tranches} \
      --truth-sensitivity-filter-level 99.0 \
      --exclude-filtered \
      --create-output-variant-index true \
      -mode INDEL

    ${GATK} --java-options "-Xmx5g -Xms5g" \
      ApplyVQSR \
      -O ${params.cohort}.recalibrated.vcf \
      -V tmp.indel.recalibrated.vcf \
      --recal-file ${snps_recalibration} \
      --tranches-file ${snps_tranches} \
      --truth-sensitivity-filter-level 99.5 \
      --exclude-filtered \
      --create-output-variant-index true \
      -mode SNP
		
	"""
}	






