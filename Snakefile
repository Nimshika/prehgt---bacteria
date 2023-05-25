import pandas as pd
import csv
import os

class checkpoint_accessions_to_genus:
    """
    Define a class to bind accession to genus for pangenome calculation. 
    This approach is documented at this url:
    http://ivory.idyll.org/blog/2021-snakemake-checkpoints.html
    """
    def __init__(self, pattern):
        self.pattern = pattern

    def get_genome_accessions(self, genus):
        genus_csv = f'outputs/accessions_to_genus/{genus}.csv'
        assert os.path.exists(genus_csv)

        genome_accessions = []
        with open(genus_csv, 'rt') as fp:
           r = csv.DictReader(fp)
           for row in r:
               accession = row['accession'].split(' ')[0]
               genome_accessions.append(accession)

        return genome_accessions

    def __call__(self, w):
        global checkpoints
        checkpoints.accessions_to_genus.get(**w) # run when rule accessions_to_genus is finished
        genome_accessions = self.get_genome_accessions(w.genus) # parse accessions in gather output file
        p = expand(self.pattern, accession=genome_accessions, **w)
        return p


metadata = pd.read_csv("inputs/venoms.tsv", header = 0, sep = "\t")
#metadata = pd.read_csv("inputs/candidate_fungi_for_bio_test_data_set.tsv", header = 0, sep = "\t")
source = ["genome"]
metadata = metadata.loc[metadata['source'].isin(source)] 
GENUS = metadata['genus'].unique().tolist()

# explanation of wildcards:
# genus (defined by GENUS): All of the genera that the pipeline will be executed on. This is defined from an input metadata file. 
# accession (inferred from checkpoint_accessions_to_genus): While all genome accessions are recorded in the metadata file, this snakefile uses the class checkpoint_accessions_to_genus to create a mapping between accessions and the genera they occur in. 

rule all:
    input: 
        "outputs/hgt_candidates_final/results_venoms.tsv"
        
###################################################
## download references
###################################################

rule download_reference_genomes:
    '''
    Using genome accessions defined in the input metadata file (e.g. GCA_018360135.1), this rule uses the ncbi-genome-download tool to download the GFF annotation file and coding domain sequence (CDS) fasta file. 
    Most genomes have long names; this rule also truncates the file names after the accession.
    '''
    output: 
        cds="inputs/genbank/{accession}_cds_from_genomic.fna.gz",
        gff="inputs/genbank/{accession}_genomic.gff.gz",
        metadata="inputs/genbank/{accession}.tsv"
    conda: "envs/ncbi-genome-download.yml"
    params: outdir="inputs/genbank/"
    benchmark: "benchmarks/download_reference_genomes/{accession}.tsv"
    shell:'''
    ncbi-genome-download all -s genbank -o {params.outdir} --flat-output -m {output.metadata} --assembly-accessions {wildcards.accession} -F gff,cds-fasta
    mv {params.outdir}{wildcards.accession}*_cds_from_genomic.fna.gz {output.cds}
    mv {params.outdir}{wildcards.accession}*_genomic.gff.gz {output.gff}
    '''

rule decompress_genome:
    '''
    Some tools require decompressed files.
    '''
    input: "inputs/genbank/{accession}_cds_from_genomic.fna.gz"
    output: "outputs/genbank/{accession}_cds_from_genomic.fna"
    benchmark: "benchmarks/decompress_reference_genomes/{accession}.tsv"
    shell:'''
    gunzip -c {input} > {output}
    '''

###################################################
## generate pangenome
###################################################

checkpoint accessions_to_genus:
    input: metadata="inputs/venoms.tsv"
    #input: metadata="inputs/candidate_fungi_for_bio_test_data_set.tsv"
    '''
    The input metadata file defines the taxonomic lineage of each of the input genomes.
    This rule creates a CSV file with all of the genomes that belong to a given genus.
    It generates the wildcard genus, which is defined from the input metadata file at the top of the snakefile.
    This checkpoint is not how checkpoints are usually used in snakemake.
    Instead, it interacts with the class checkpoint_accessions_to_genus.
    That class is run after this rule is executed, where it maps all of the accessions that belong to a given genus.
    '''
    output: genus="outputs/accessions_to_genus/{genus}.csv",
    conda: "envs/tidyverse.yml"
    benchmark: "benchmarks/accessions_to_genus/{genus}.tsv"
    script: "scripts/accessions_to_genus.R"

rule combine_cds_per_genus:
    '''
    Using the class checkpoint_accessions_to_genus, this rule combines all CDS sequences from all accessions that belong to a given genus into one file so they can be clustered into a "pangenome."
    '''
    input: checkpoint_accessions_to_genus('outputs/genbank/{accession}_cds_from_genomic.fna')
    output: "outputs/genus_pangenome_raw/{genus}_cds.fna"
    benchmark: "benchmarks/combine_cds_per_genus/{genus}.tsv"
    shell:'''
    cat {input} > {output}
    '''

rule combine_and_parse_gff_per_genus:
    '''
    Using the class checkpoint_accessions_to_genus, this rule combines all GFF annotation files from all accessions that belong to a given genus into one file.
    After pangenome clustering, this file will be used to retrieve information (genomic coords, etc) for rep sequences.
    '''
    input: gff = checkpoint_accessions_to_genus('inputs/genbank/{accession}_genomic.gff.gz')
    output: gff = "outputs/genus_pangenome_raw/{genus}_gff_info.tsv"
    benchmark: "benchmarks/combine_gff_per_genus/{genus}.tsv"
    conda: "envs/tidyverse.yml"
    script: "scripts/combine_and_parse_gff_per_genus.R"

rule build_genus_pangenome:
    '''
    This rule clusters all CDS sequences from all accessions in a given genus into a pangenome.
    This reduces redundancy for subsequent searches, and this information can be leveraged to interpret the HGT candidate genes that will eventually be predicted by the pipeline.
    selecting clustering threshold:
    0.9 https://www.science.org/doi/full/10.1126/sciadv.aba0111
    0.98, 0.99 https://www.sciencedirect.com/science/article/pii/S0960982220314263
    0.9 https://www.pnas.org/doi/abs/10.1073/pnas.2009974118
    '''
    input: "outputs/genus_pangenome_raw/{genus}_cds.fna"
    output: 
        "outputs/genus_pangenome_clustered/{genus}_cds_rep_seq.fasta",
        "outputs/genus_pangenome_clustered/{genus}_cds_cluster.tsv"
    conda: "envs/mmseqs2.yml"
    benchmark:"benchmarks/genus_pangenome/{genus}.tsv"
    params: outprefix = lambda wildcards: "outputs/genus_pangenome_clustered/" + wildcards.genus + "_cds"
    shell:'''
    mmseqs easy-cluster {input} {params.outprefix} tmp_mmseqs2 --min-seq-id 0.9
    '''

rule translate_pangenome:
    '''
    Translate the representative pangenome sequences from nucleotide to amino acid
    '''
    input: "outputs/genus_pangenome_clustered/{genus}_cds_rep_seq.fasta"
    output: "outputs/genus_pangenome_clustered/{genus}_aa_rep_seq.fasta"
    conda: "envs/emboss.yml"
    benchmark: "benchmarks/translate_pangenome/{genus}.tsv"
    shell:'''
    transeq -sequence {input} -outseq {output}
    '''

##################################################
## DNA compositional screen
###################################################

rule compositional_scans_pepstats:
    '''
    This rule uses emboss pepstats to calculate relative amino acid usage per pangenome seq
    '''
    input: "outputs/genus_pangenome_clustered/{genus}_aa_rep_seq.fasta"
    output: 'outputs/compositional_scans_pepstats/{genus}_pepstats.txt'
    conda: "envs/emboss.yml"
    benchmark: "benchmarks/compositional_scans_pepstats/{genus}.tsv"
    shell:'''
    pepstats -sequence {input} -outfile {output}
    '''

rule compositional_scans_to_hgt_candidates:
    '''
    This script performs hierarchical clustering on genes based on their relative amino acid usage and identifies clusters with fewer than 150 genes. 
    The output is a list of genes that belong to these small clusters, which are considered HGT candidates.
    '''
    input: raau='outputs/compositional_scans_pepstats/{genus}_pepstats.txt',
    output: 
        tsv="outputs/compositional_scans_hgt_candidates/{genus}_clusters.tsv",
        gene_lst="outputs/compositional_scans_hgt_candidates/{genus}_gene_lst.txt"
    benchmark: "benchmarks/compositional_scans_to_hgt_candidates/{genus}.tsv"
    conda: "envs/tidyverse.yml"
    script: "scripts/compositional_scans_to_hgt_candidates.R"

###################################################
## BLASTP (diamond) against clustered nr
###################################################

rule blast_against_clustered_nr:
    '''
    This rule uses the diamond implementation of BLASTP to compare each CDS in the genus-level pangenome to a clustered version of NR.
    For more information on the database, see this repository: https://github.com/Arcadia-Science/2023-nr-clustering
    Using the diamond implementation and the clustered database decreases the time it takes to run this step. 
    '''
    input:
        db="inputs/nr_rep_seq.fasta.gz", # downloaded from S3...TBD on how to make available, its 60GB
        query="outputs/genus_pangenome_clustered/{genus}_aa_rep_seq.fasta"
    output: "outputs/blast_diamond/{genus}_vs_clustered_nr.tsv"
    conda: "envs/diamond.yml"
    benchmark: "benchmarks/blast_against_clustered_nr/{genus}.tsv"
    threads: 16
    shell:'''
    diamond blastp --db {input.db} --query {input.query} --out {output} \
        --outfmt 6 qseqid qtitle sseqid stitle pident approx_pident length mismatch gapopen qstart qend qlen qcovhsp sstart send slen scovhsp evalue bitscore score corrected_bitscore \
        --max-target-seqs 100 --threads {threads} --faster
    '''

rule blast_add_taxonomy_info:
    '''
    This rule adds taxonomic lineages to each BLAST match.
    The taxonomy sheet records the lowest common ancestor for a BLAST match, given that all BLAST matches represent a cluster of proteins.
    Because the taxonomy sheet is so large (>60GB), the script uses an sql query executed via dplyr and dbplyr to decrease search times.
    '''
    input: 
        tsv="outputs/blast_diamond/{genus}_vs_clustered_nr.tsv",
        sqldb="inputs/nr_cluster_taxid_formatted_final.sqlite" # downloaded from S3...TBD on how to make available, it's 63 GB
    output: tsv="outputs/blast_diamond/{genus}_vs_clustered_nr_lineages.tsv"
    params: sqldb_tbl="nr_cluster_taxid_table"
    conda: "envs/r-sql.yml"
    benchmark: "benchmarks/blast_add_taxonomy_info/{genus}.tsv"
    script: "scripts/blast_add_taxonomy_info.R"

rule blast_to_hgt_candidates:
    '''
    This script processes BLAST matches and their taxonomic lineages to identify HGT candidates using alien index, horizontal gene transfer index, donor distribution index, and acceptor lowest common acnestor calculations.
    It scores all candidates and highlights where contamination is likely.
    It writes the scores and other relevant information to a TSV file and outputs a list of candidate gene IDs.
    '''
    input: tsv="outputs/blast_diamond/{genus}_vs_clustered_nr_lineages.tsv"
    output: 
        gene_lst="outputs/blast_hgt_candidates/{genus}_gene_lst.txt",
        tsv="outputs/blast_hgt_candidates/{genus}_blast_scores.tsv"
    conda: "envs/tidyverse.yml"
    benchmark: "benchmarks/blast_to_hgt_candidates/{genus}.tsv"
    script: "scripts/blast_to_hgt_candidates.R"

###################################################
## candidate characterization
###################################################

rule combine_hgt_candidates:
    '''
    This rule combines the lists of HGT candidate genes identified through two different methods - BLAST and compositional scans. 
    The output is a single list containing the unique genes from both input lists.
    * cat {input}: stream the input file to stdin
    * csvtk freq -H -f 1: for the headerless CSV that is being streamed in (it's a one column txt file so delimiter isn't important), count the frequency of each term in the first field.
      The frequency is reported as a new column, and duplicated terms are collapsed in the first column.
    * csvtk cut -f 1 -o {output}: cut the first column (the no de-duplicated hgt candidate names) and output it to a file.
    '''
    input: 
       "outputs/blast_hgt_candidates/{genus}_gene_lst.txt",
       "outputs/compositional_scans_hgt_candidates/{genus}_gene_lst.txt"
    output: "outputs/hgt_candidates/{genus}_gene_lst.txt"
    conda: "envs/csvtk.yml"
    shell:'''
    cat {input} | csvtk freq -H -f 1 | csvtk cut -f 1 -o {output}
    '''

rule extract_hgt_candidates:
    '''
    This rule extracts the DNA sequences of the HGT candidate genes from the pangenome clusters. 
    The output is a FASTA file containing the sequences of the identified HGT candidate genes.
    '''
    input:
        fa = "outputs/genus_pangenome_clustered/{genus}_aa_rep_seq.fasta", 
        gene_lst = "outputs/hgt_candidates/{genus}_gene_lst.txt"
    output: "outputs/hgt_candidates/{genus}_aa.fasta"
    benchmark: "benchmarks/extract_hgt_candidates/{genus}.tsv"
    conda: "envs/seqtk.yml"
    shell:'''
    seqtk subseq {input.fa} {input.gene_lst} > {output}
    '''

rule download_eggnog_db:
    """
    This rule downloads the eggnog annotation database.
    The script download_eggnog_data.py is exported by the eggnog mapper tool.
    """
    output: "inputs/eggnog_db/eggnog.db"
    conda: "envs/eggnog.yml"
    shell:'''
    download_eggnog_data.py -H -d 2 -y --data_dir inputs/eggnog_db
    '''

rule eggnog_hgt_candidates:
    '''
    This rule uses the EggNOG database to functionally annotate the HGT candidate genes. 
    It runs the EggNOG-Mapper tool on the translated candidate gene sequences, generating a file with the annotations (NOG, KEGG, PFAM, CAZys, EC numbers) for each gene. 
    The script emapper.py is exported by the eggnog mapper tool.
    '''
    input:
        db="inputs/eggnog_db/eggnog.db",
        fa="outputs/hgt_candidates/{genus}_aa.fasta"
    output: "outputs/hgt_candidates_annotation/eggnog/{genus}.emapper.annotations",
    conda: "envs/eggnog.yml"
    params:
        outdir="outputs/hgt_candidates_annotation/eggnog/",
        dbdir = "inputs/eggnog_db" 
    threads: 8
    benchmark: "benchmarks/eggnog_hgt_candidates/{genus}.tsv"
    shell:'''
    mkdir -p tmp
    emapper.py --cpu {threads} -i {input.fa} --output {wildcards.genus} \
       --output_dir {params.outdir} -m diamond --tax_scope none \
       --seed_ortholog_score 60 --override --temp_dir tmp/ \
       --data_dir {params.dbdir}
    '''

rule hmmscan_hgt_candidates:
    '''
    Using the hmm file built in make_hmm_db.snakefile, this rule uses hidden markov models to annotate specific protein classes of interest.
    At the moment it targets viruses and biosynthetic gene clusters, but the HMM file can be expanded in the aforementioned snakefile as desired. 
    '''
    input:
        hmmdb="inputs/hmms/all_hmms.hmm",
        fa="outputs/hgt_candidates/{genus}_aa.fasta"
    output:
        tblout="outputs/hgt_candidates_annotation/hmmscan/{genus}.tblout",
        out="outputs/hgt_candidates_annotation/hmmscan/{genus}.out"
    conda: "envs/hmmer.yml"
    threads: 8
    benchmark: "benchmarks/hmmscan_hgt_candidates/{genus}.tsv"
    shell:'''
    hmmscan --cpu {threads} --tblout {output.tblout} -o {output.out} {input.hmmdb} {input.fa}
    '''

###################################################
## Combine results
###################################################

rule combine_results:
    '''
    Combine all of the results into a single mega TSV file.
    The results are joined either on the genus or on the HGT candidate gene name, derived from the pangenome FASTA file.
    '''
    input: 
        compositional = expand("outputs/compositional_scans_hgt_candidates/{genus}_clusters.tsv", genus = GENUS),
        blast = expand("outputs/blast_hgt_candidates/{genus}_blast_scores.tsv", genus = GENUS),
        eggnog = expand("outputs/hgt_candidates_annotation/eggnog/{genus}.emapper.annotations", genus = GENUS),
        hmmscan = expand("outputs/hgt_candidates_annotation/hmmscan/{genus}.tblout", genus = GENUS),
        acc_to_genus = expand("outputs/accessions_to_genus/{genus}.csv", genus = GENUS),
        pangenome_cluster = expand("outputs/genus_pangenome_clustered/{genus}_cds_cluster.tsv", genus = GENUS),
        gff = expand("outputs/genus_pangenome_raw/{genus}_gff_info.tsv", genus = GENUS)
    output: 
        all_results = "outputs/hgt_candidates_final/results_venoms.tsv",
        method_tally = "outputs/hgt_candidates_final/method_tally_venoms.tsv"
    conda: "envs/tidyverse.yml"
    script: "scripts/combine_results.R"