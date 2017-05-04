#!/usr/bin/env perl

## author: reubwn Nov 2016

use strict;
use warnings;

use Getopt::Long;
use Sort::Naturally;
use Data::Dumper qw(Dumper);
use List::Util qw(reduce sum min max);

my $usage = "
SYNOPSIS
  Goal is to take a taxified Diamond or BLAST file, and for each hit recurse up the tax tree until
  that hit can be categorised into **INGROUP** versus **OUTGROUP** (e.g., Metazoa vs non-Metazoa).

  1. Calculate HGT Index (hU): Calculate hU based on best bitscores to INGROUP vs OUTGROUP (default >= 30)
  2. Get Query Category: For each query, calculate the bitscoresum for ingroup vs outgroup across **all hits**;
     the category with the highest bitscoresum is the \"winner\"
  3. Get Consensus Hit Support: Assess support for the winning query taxid from secondary hits; winning taxid
     is well-supported if the rest of the hits agree with the INGROUP/OUTGROUP categorisation above --support_threshold
     (default = 90%)
  4. Print: General results printed to *.HGT_results, candidate HGT genes printed to *.HGT_candidates (default
     is to print candidates passing both hU and CHS thresholds)

DEFINITIONS
    HGT Index (hU) = (Best-hit bitscore for non-Metazoa) - (Best-hit bitscore for Metazoa)
    Alien Index (AI) = log10((Best-hit Evalue for Metazoa) + 1e-200) - log10((Best-hit Evalue for non-Metazoa) + 1e-200)
    Consesus Hit Support (CHS) = Proportion of all hits that agree with hU classification

OUTPUTS
  A \"\*.HGT_results.txt\" file with the support values for each query; a \"\*.HGT_candidates.txt\" file with queries
  showing support over the specified thresholds.

OPTIONS
  -i|--in                [FILE]   : taxified diamond/BLAST results file [required]
  -p|--path              [STRING] : path to dir/ containing tax files
  -o|--nodes             [FILE]   : path to nodes.dmp
  -a|--names             [FILE]   : path to names.dmp
  -m|--merged            [FILE]   : path to merged.dmp
  -n|--nodesDB           [FILE]   : nodesDB.txt file from blobtools
  -g|--gff               [FILE]   : path to augustus-formatted GFF file [TODO]
  -t|--taxid_ingroup     [INT]    : NCBI taxid to define 'ingroup' [default = 33208 (Metazoa)]
  -k|--taxid_skip        [INT]    : NCBI taxid to skip; hits to this taxid will not be considered
  -s|--support_threshold [FLOAT]  : Secondary Hits Support threshold for considering HGT candidates [default >= 90\%]
  -l|--hU_threshold      [INT]    : hU threshold for HGT candidates (default>=30) (also controls AI threshold )
  -@|--AI                         : use AI instead of hU [default = hU]
  -e|--evalue_column     [INT]    : define evalue column for --in (first column = 1) [default=11]
  -b|--bitscore_column   [INT]    : define bitscore column for --in (first column = 1) [default=12]
  -c|--taxid_column      [INT]    : define taxid column for --in (first column = 1) [default=13]
  -d|--delimiter         [STRING] : infile delimiter (diamond (\"\\s+\") or blast (\"\\t\")) [default=diamond]
  -x|--prefix            [FILE]   : filename prefix for outfile [default=INFILE]
  -v|--verbose                    : say more things
  -h|--help                       : this help message
\n";

my ($in,$nodesfile,$path,$namesfile,$mergedfile,$nodesDBfile,$gff,$prefix,$outfile,$hgtcandidatesfile,$warningsfile,$header,$useai,$verbose,$debug,$help);
my $taxid_threshold = 33208; ##metazoa
my $taxid_skip = 0; ##default is 0, not a valid NCBI taxid and should not affect the tree recursion
my $support_threshold = 90;
my $hU_threshold = 30;
my $scoring = "sum";
my $evalue_column = 11;
my $bitscore_column = 12;
my $taxid_column = 13;
my $delimiter = "diamond";

GetOptions (
  'in|i=s'                => \$in,
  'path|p:s'              => \$path,
  'nodes|o:s'             => \$nodesfile,
  'names|a:s'             => \$namesfile,
  'merged|m:s'            => \$mergedfile,
  'nodesDB|n:s'           => \$nodesDBfile,
  'gff|g:s'               => \$gff,
  'taxid_threshold|t:i'   => \$taxid_threshold,
  'taxid_skip|k:i'        => \$taxid_skip,
  'support_threshold|s:f' => \$support_threshold,
  'hU_threshold|l:i'      => \$hU_threshold,
#  'scoring|r:s'           => \$scoring,
  'AI|@'                  => \$useai, ##default is HGT index
  'evalue_column|e:i'     => \$evalue_column,
  'taxid_column|c:i'      => \$taxid_column,
  'bitscore_column|b:i'   => \$bitscore_column,
  'delimiter|d:s'         => \$delimiter,
  'prefix|x:s'            => \$prefix,
#  'header|H'              => \$header,
  'verbose|v'             => \$verbose,
  'debug'                 => \$debug,
  'help|h'                => \$help,
);

die $usage if $help;
die $usage unless ($in);
#die $usage unless (($nodesfile && $namesfile) || $nodesDBfile || $path);

## define delimiter:
if ($delimiter eq "diamond") {
  $delimiter = qr/\s+/;
} elsif ($delimiter eq "blast") {
  $delimiter = qr/\t/;
} else {
  die "[ERROR] Unknown delimiter, please choose \"diamond\" or \"blast\"\n";
}

############################################## PARSE NODES

## parse nodes and names:
my (%nodes_hash, %names_hash, %rank_hash);
if ($path) {
  print STDERR "[INFO] Building taxonomy databases from tax files in '$path'...";
  open(my $NODES, "$path/nodes.dmp") or die $!;
  while (<$NODES>) {
    chomp;
    next if /\#/;
    my @F = map { s/^\s+|\s+$//gr } split (/\|/, $_); ## split nodes.dmp file on \s+|\s+ regex
    $nodes_hash{$F[0]} = $F[1]; ## key= child taxid; value= parent taxid
    $rank_hash{$F[0]} = $F[2]; ## key= taxid; value= rank
  }
  close $NODES;
  open (my $NAMES, "$path/names.dmp") or die $!;
  while (<$NAMES>) {
    chomp;
    next if /\#/;
    my @F = map { s/^\s+|\s+$//gr } split (/\|/, $_);
    $names_hash{$F[0]} = $F[1] if ($F[3] eq "scientific name"); ## key= taxid; value= species name
  }
  close $NAMES;
  if (-e "$path/merged.dmp") {
    open (my $MERGED, "$path/merged.dmp") or die $!;
    while (<$MERGED>) {
      chomp;
      next if /\#/;
      my @F = map { s/^\s+|\s+$//gr } split (/\|/, $_);
      $nodes_hash{$F[0]} = $F[1]; ## key= old taxid; value= new taxid
      ## this will behave as if old taxid is a child of the new one, which is OK I guess
    }
  }
} elsif ($nodesfile && $namesfile) {
  #select((select(STDERR), $|=1)[0]);
  print STDERR "[INFO] Building taxonomy databases from '$nodesfile' and '$namesfile'...";
  open(my $NODES, $nodesfile) or die $!;
  while (<$NODES>) {
    chomp;
    next if /\#/;
    my @F = map { s/^\s+|\s+$//gr } split (/\|/, $_); ## split nodes.dmp file on \s+|\s+ regex
    $nodes_hash{$F[0]} = $F[1]; ## key= child taxid; value= parent taxid
    $rank_hash{$F[0]} = $F[2]; ## key= taxid; value= rank
  }
  close $NODES;
  open (my $NAMES, $namesfile) or die $!;
  while (<$NAMES>) {
    chomp;
    next if /\#/;
    my @F = map { s/^\s+|\s+$//gr } split (/\|/, $_);
    $names_hash{$F[0]} = $F[1] if ($F[3] eq "scientific name"); ## key= taxid; value= species name
  }
  close $NAMES;
  if ($mergedfile) {
    open (my $MERGED, $mergedfile) or die $!;
    while (<$MERGED>) {
      chomp;
      next if /\#/;
      my @F = map { s/^\s+|\s+$//gr } split (/\|/, $_);
      $nodes_hash{$F[0]} = $F[1]; ## key= old taxid; value= new taxid
      ## this will behave as if old taxid is a child of the new one, which is OK I guess
    }
  }
} elsif ($nodesDBfile) {
  print STDERR "[INFO] Building taxonomy databases from '$nodesDBfile'...";
  open(my $NODES, $nodesDBfile) or die $!;
  while (<$NODES>) {
    chomp;
    next if /\#/;
    my @F = split (/\t/, $_);
    $nodes_hash{$F[0]} = $F[3]; ## key= child taxid; value= parent taxid
    $names_hash{$F[0]} = $F[2]; ## key= taxid; value= species name
    $rank_hash{$F[0]} = $F[1]; ## key= taxid; value= rank
  }
  close $NODES;
}
## print some info to STDERR:
print STDERR " done\n";
print STDERR "[INFO] Nodes parsed: ".scalar(keys %nodes_hash)."\n";
print STDERR "[INFO] Threshold taxid set to '$taxid_threshold' ($names_hash{$taxid_threshold})\n";
print STDERR "[INFO] INGROUP set to '$names_hash{$taxid_threshold}'; OUTGROUP is therefore 'non-$names_hash{$taxid_threshold}'\n";
if ($taxid_skip) {
  print STDERR "[INFO] Skipping any hits to taxid '$taxid_skip' ($names_hash{$taxid_skip})\n";
} else {
  print STDERR "[WARN] Taxid to skip (-k) is not set! Suggest setting -k to the taxid of the phylum your organism comes from.\n";
}
print STDERR "[INFO] Scoring method set to '$scoring'\n";

############################################ OUTFILES

## define outfiles:
if ($prefix) {
  $outfile = "$prefix.HGT_results.$names_hash{$taxid_threshold}.txt";
  $hgtcandidatesfile = "$prefix.HGT_candidates.$names_hash{$taxid_threshold}.supp$support_threshold.hU$hU_threshold.txt";
  $warningsfile = "$prefix.HGT_warnings.txt";
} else {
  $outfile = "$in.HGT_results.$names_hash{$taxid_threshold}.txt";
  $hgtcandidatesfile = "$in.HGT_candidates.$names_hash{$taxid_threshold}.supp$support_threshold.hU$hU_threshold.txt";
  $warningsfile = "$in.HGT_warnings.txt";
}

## open outfiles:
open (my $OUT, ">",$outfile) or die $!;
open (my $HGT, ">",$hgtcandidatesfile) or die $!;
open (my $WARN, ">",$warningsfile) or die $!;
my @header = (
  "QUERY",
  "INGROUP",
  "hU",
  "BIT_OUT",
  "BIT_IN",
  "AI",
  "EVAL_OUT",
  "EVAL_IN",
  "BBSUMCAT",
  "CHS",
  "TAXONOMY"
);
print $OUT join ("\t", "\#", @header, "\n"); #"\#query\tbestsum_bitscore\talt_bitscore\tingroup_taxname\tdecision\tsupport\tbest_ingroup_evalue\tbest_outgroup_evalue\talien_index\tbesthit_taxonomy\n" unless $header;
print $HGT join ("\t", "\#", @header, "\n"); #"\#query\tbestsum_bitscore\talt_bitscore\tingroup_taxname\tdecision\tsupport\tbest_ingroup_evalue\tbest_outgroup_evalue\talien_index\tbesthit_taxonomy\n" unless $header;

############################################## PARSE DIAMOND

## parse Diamond file:
print STDERR "[INFO] Parsing Diamond file '$in'...";
my (%bitscores_per_query_hash, %evalues_per_query_hash);
my ($total_entries,$skipped_entries_because_bad_taxid,$skipped_entries_because_skipped_taxid,$skipped_entries_because_unassigned) = (0,0,0,0);
open (my $DIAMOND, $in) or die $!;
while (<$DIAMOND>) {
  chomp;
  next if /^\#/;
  $total_entries++;
  my @F = split ($delimiter, $_);
  if ($F[($taxid_column-1)] !~ m/\d+/) {
    print $WARN join ("\t", $F[0], $., $F[($taxid_column-1)], "invalid/unrecognised taxid", "\n");
    $skipped_entries_because_bad_taxid++;
    next;
  } elsif (check_taxid_has_parent($F[($taxid_column-1)]) == 1) {
    print $WARN join ("\t", $F[0], $., $F[($taxid_column-1)], "invalid/unrecognised parent taxid", "\n");
    $skipped_entries_because_bad_taxid++;
    next;
  } elsif ( tax_walk($F[($taxid_column-1)], $taxid_skip) eq "ingroup" ) { ## do not include any hits to within taxid $taxid_skip
    print $WARN join ("\t", $F[0], $., $F[($taxid_column-1)], "taxid within skipped ($taxid_skip)", "\n") if $verbose;
    $skipped_entries_because_skipped_taxid++;
    next;
  } elsif ( tax_walk($F[($taxid_column-1)]) eq "unassigned" ) {
    print $WARN join ("\t", $F[0], $., $F[($taxid_column-1)], "taxid unassigned/unclassified", "\n");
    $skipped_entries_because_unassigned++;
    next;
  } else {
    ## push all bitscores and evalues for every taxid into an array within a hash within a hash:
    push @{ $bitscores_per_query_hash{$F[0]}{$F[($taxid_column-1)]} }, $F[($bitscore_column-1)]; ## key= query; value= hash{ key= taxid; value= array[ bitscores ]}
    push @{ $evalues_per_query_hash{$F[0]}{$F[($taxid_column-1)]} }, $F[$evalue_column-1]; ## key= query; value= hash{ key= taxid; value= array [ evalues ]}
  }
}
close $DIAMOND;
print STDERR " done\n\n";
print STDERR "[INFO] Total number of hits parsed: ".commify($total_entries)."\n";
print STDERR "[WARN] There were $skipped_entries_because_bad_taxid (".percentage($skipped_entries_because_bad_taxid,$total_entries)."\%) invalid taxid entries\n" if $skipped_entries_because_bad_taxid > 0;
print STDERR "[WARN] There were $skipped_entries_because_skipped_taxid (".percentage($skipped_entries_because_skipped_taxid,$total_entries)."\%) skipped taxid entries\n" if $skipped_entries_because_skipped_taxid > 0;
print STDERR "[WARN] There were $skipped_entries_because_unassigned (".percentage($skipped_entries_because_unassigned,$total_entries)."\%) unassigned/unclassified taxid entries\n" if $skipped_entries_because_unassigned > 0;

############################################ DEBUG

print Dumper \%bitscores_per_query_hash if $debug;
print Dumper \%evalues_per_query_hash if $debug;

############################################ MAIN

## get winning bitscore and taxid; calculate congruence among all taxids for all hits per query:
my ($processed,$ingroup,$ingroup_supported,$outgroup,$outgroup_supported,$hU_supported,$AI_supported,$unassigned) = (0,0,0,0,0,0,0);
my %hgt_candidates;
print STDERR "[INFO] Calculating bestsum bitscore and hit support...\n";
print STDERR "\n" if $verbose;
foreach my $query (nsort keys %bitscores_per_query_hash) {
  my %bitscore_hash = %{ $bitscores_per_query_hash{$query} }; ## key= taxid; value= \@array of all bitscores for that taxid
  my %evalue_hash = %{ $evalues_per_query_hash{$query} }; ## key= taxid; value= \@array of all evalues for that taxid

  ## calculate alien index (AI):
  my ($ingroup_best_evalue, $outgroup_best_evalue) = (1,1);
  foreach my $taxid (keys %evalue_hash) {
    my $min_evalue = min( @{ $evalue_hash{$taxid} } );
    if (tax_walk($taxid) eq "ingroup") {
      $ingroup_best_evalue = $min_evalue if ($min_evalue < $ingroup_best_evalue); ## only accept it if it's LOWER (better) than current Evalue
    } elsif (tax_walk($taxid) eq "outgroup") {
      $outgroup_best_evalue = $min_evalue if ($min_evalue < $outgroup_best_evalue);
    }
  }
  ## AI = log(AI_in+constant) - log(AI_out+constant):
  my $AI = ( log10($ingroup_best_evalue + 1e-200) - log10($outgroup_best_evalue + 1e-200) );
  $AI_supported++ if $AI >= $hU_threshold;

  ## calculate HGT index (hU):
  my ($ingroup_best_bitscore, $outgroup_best_bitscore) = (0,0);
  foreach my $taxid (keys %bitscore_hash) {
    my $max_bitscore = max( @{ $bitscore_hash{$taxid} } );
    if (tax_walk($taxid) eq "ingroup") {
      $ingroup_best_bitscore = $max_bitscore if ($max_bitscore > $ingroup_best_bitscore); ## only accept it if it's HIGHER (better) than current bitscore
    } elsif (tax_walk($taxid) eq "outgroup") {
      $outgroup_best_bitscore = $max_bitscore if ($max_bitscore > $outgroup_best_bitscore);
    }
  }
  ## hU = B_out - B_in:
  my $hU = ($outgroup_best_bitscore - $ingroup_best_bitscore);
  $hU_supported++ if $hU >= $hU_threshold;

  ## calculate bitscoresums per taxid; get taxid of highest bitscoresum; get support for winning taxid from other hits:
  my (%bitscoresum_hash, %count_categories, %support_categories);
  my ($ingroup_bitscoresum, $outgroup_bitscoresum) = (0,0);

  foreach my $taxid (keys %bitscore_hash) {
    if ($scoring eq "sum") {
      if (tax_walk($taxid) eq "ingroup") {
        $ingroup_bitscoresum += sum( @{ $bitscore_hash{$taxid} } );
        #print STDERR join "\t", "\t", $query, $taxid, tax_walk($taxid), sum( @{ $bitscore_hash{$taxid} } ),"\n"; ## uncomment to see info for each each hit
      } elsif (tax_walk($taxid) eq "outgroup") {
        $outgroup_bitscoresum += sum( @{ $bitscore_hash{$taxid} } );
        #print STDERR join "\t", "\t", $query, $taxid, tax_walk($taxid), sum( @{ $bitscore_hash{$taxid} } ),"\n"; ## uncomment to see info for each each hit
      }
      my $bitscoresum = sum( @{ $bitscore_hash{$taxid} } );
      $bitscoresum_hash{$taxid} = $bitscoresum; ## key= taxid; value= bitscoresum
    } elsif ($scoring eq "individual") {
      my $bitscoresum = sum( @{ $bitscore_hash{$taxid} } );
      $bitscoresum_hash{$taxid} = $bitscoresum; ## key= taxid; value= bitscoresum
    }
    $count_categories{tax_walk($taxid)}++; ## count categories; if each hit's taxid falls within/outwith the $taxid_threshold
  }
  print "$query:\n" if $debug; ## debug
  print Dumper \%bitscoresum_hash if $debug; ## debug

  foreach my $cat (keys %count_categories) {
    $support_categories{$cat} = percentage($count_categories{$cat}, scalar(keys %bitscore_hash)); ## calculate proportion of support for the category of the winner
  }

  ## get taxid with highest bitscore:
  my ($taxid_with_highest_bitscore,$taxid_with_highest_bitscore_category,$taxid_with_highest_bitscore_category_support);
  if ($scoring eq "sum") {
    $taxid_with_highest_bitscore_category = $ingroup_bitscoresum > $outgroup_bitscoresum ? "ingroup" : "outgroup"; ## define query category based on bitscoresums of ingroup vs outgroup
    $taxid_with_highest_bitscore_category_support = $support_categories{$taxid_with_highest_bitscore_category}; ## % support from other hits
    $taxid_with_highest_bitscore = List::Util::reduce { $bitscoresum_hash{$b} > $bitscoresum_hash{$a} ? $b : $a } keys %bitscoresum_hash; ## winning taxid
    print STDERR "[INFO] [$query] Bitscoresum for INGROUP ($names_hash{$taxid_threshold}): $ingroup_bitscoresum\n" if $verbose;
    print STDERR "[INFO] [$query] Bitscoresum for OUTGROUP (non-$names_hash{$taxid_threshold}): $outgroup_bitscoresum\n" if $verbose;
    ## PRINT TO OUT:
    print $OUT join (
      "\t",
      $query, ##QUERY
      $names_hash{$taxid_threshold}, ##INGROUP
      $hU, ##hU
      $outgroup_best_bitscore, ##BIT_OUT
      $ingroup_best_bitscore, ##BIT_IN
      $AI, ##AI
      $outgroup_best_evalue, ##EVAL_OUT
      $ingroup_best_evalue, ##EVAL_IN
      ($ingroup_bitscoresum > $outgroup_bitscoresum ? "INGROUP" : "OUTGROUP"), ##BBSUMCAT
      $taxid_with_highest_bitscore_category_support, ##CHS
      tax_walk_to_get_rank_to_phylum($taxid_with_highest_bitscore), ##TAXONOMY
       "\n"
    );

  } elsif ($scoring eq "individual") {
    die "[ERROR] Sorry, individual scoring not supported, please change to 'sum'\n";
    # $taxid_with_highest_bitscore = List::Util::reduce { $bitscoresum_hash{$b} > $bitscoresum_hash{$a} ? $b : $a } keys %bitscoresum_hash; ## winning taxid
    # $taxid_with_highest_bitscore_category = tax_walk($taxid_with_highest_bitscore); ## category of winning taxid ("ingroup", "outgroup" or "unassigned")
    # $taxid_with_highest_bitscore_category_support = $support_categories{$taxid_with_highest_bitscore_category}; ## % support from other hits
    # print STDERR "[INFO] [$query] Taxid with highest bitscore: $taxid_with_highest_bitscore (bitscore = $bitscoresum_hash{$taxid_with_highest_bitscore}; taxonomy = ".tax_walk_to_get_rank_to_phylum($taxid_with_highest_bitscore).")\n" if $verbose;
    # print $OUT join "\t", $query, $taxid_with_highest_bitscore, $bitscoresum_hash{$taxid_with_highest_bitscore}, tax_walk_to_get_rank_to_phylum($taxid_with_highest_bitscore), $names_hash{$taxid_threshold}, $taxid_with_highest_bitscore_category, $taxid_with_highest_bitscore_category_support, $alien_index, "\n";

  }

  print STDERR "[INFO] [$query] Decision of bestsum bitscore: '$taxid_with_highest_bitscore_category' (support = $taxid_with_highest_bitscore_category_support)\n" if $verbose;
  print STDERR "[INFO] [$query] Best evalue for INGROUP ($names_hash{$taxid_threshold}): $ingroup_best_evalue\n" if $verbose;
  print STDERR "[INFO] [$query] Best evalue for OUTGROUP (non-$names_hash{$taxid_threshold}): $outgroup_best_evalue\n" if $verbose;
  print STDERR "[INFO] [$query] Alien Index = $AI\n[----]\n" if $verbose;

  ## count genes in various categories:
  if ( $taxid_with_highest_bitscore_category eq "unassigned" ) {
    $unassigned++;
  } elsif ( $taxid_with_highest_bitscore_category eq "ingroup" ) {
    $ingroup++;
    $ingroup_supported++ if ( $taxid_with_highest_bitscore_category_support >= $support_threshold );
  } elsif ( $taxid_with_highest_bitscore_category eq "outgroup" ) {
    $outgroup++;
    $outgroup_supported++ if ( $taxid_with_highest_bitscore_category_support >= $support_threshold );
  }

  ## PRINT TO HGT_CANDIDATES:
  ## print all queries with hU>=threshold AND CHS>=threshold to HGT_candidates file:
  if ( ($hU >= $hU_threshold) && ($taxid_with_highest_bitscore_category eq "outgroup") && ($taxid_with_highest_bitscore_category_support >= $support_threshold) ) {
    print $HGT join (
      "\t",
      $query, ##QUERY
      $names_hash{$taxid_threshold}, ##INGROUP
      $hU, ##hU
      $outgroup_best_bitscore, ##BIT_OUT
      $ingroup_best_bitscore, ##BIT_IN
      $AI, ##AI
      $outgroup_best_evalue, ##EVAL_OUT
      $ingroup_best_evalue, ##EVAL_IN
      ($ingroup_bitscoresum > $outgroup_bitscoresum ? "INGROUP" : "OUTGROUP"), ##BBSUMCAT
      $taxid_with_highest_bitscore_category_support, ##CHS
      tax_walk_to_get_rank_to_phylum($taxid_with_highest_bitscore), ##TAXONOMY
      "\n"
    );
    $hgt_candidates{$query} = ();
  }

  ## progress:
  $processed++;
  if ($processed % 1000 == 0){
    print STDERR "\r[INFO] Processed ".commify($processed)." queries...";
    $| = 1;
  }
}
close $OUT;
close $HGT;
close $WARN;

print STDERR "\r[INFO] Processed ".commify($processed)." queries\n\n";
print STDERR "[INFO] TOTAL NUMBER OF HGT CANDIDATES: ".scalar(keys(%hgt_candidates))."\n";
print STDERR "[INFO] Number of queries with HGT Index (hU) >= $hU_threshold: ".commify($hU_supported)."\n";
print STDERR "[INFO] Number of queries with Alien Index (AI) >= $hU_threshold: ".commify($AI_supported)."\n";
print STDERR "[INFO] Number of queries in OUTGROUP category ('non-$names_hash{$taxid_threshold}'): ".commify($outgroup)."\n";
print STDERR "[INFO] Number of queries in OUTGROUP category ('non-$names_hash{$taxid_threshold}') with support >= $support_threshold\%: ".commify($outgroup_supported)."\n";
print STDERR "[INFO] Number of queries in unassigned/unclassified category: ".commify($unassigned)."\n" if $unassigned > 0;
print STDERR "[INFO] Finished on ".`date`."\n";

############################################ SUBS

sub check_taxid_has_parent {
  my $taxid = $_[0];
  my $result = 0;
  unless ($nodes_hash{$taxid}) {
    $result = 1;
  }
  return $result; ## 0 = taxid exists; 1 = taxid does not exist
}

sub tax_walk {
    my $taxid = $_[0];
    my $walk_to;
    if (exists $_[1]) {
      $walk_to = $_[1];
    } else {
      $walk_to = $taxid_threshold; ## default is metazoa
    }

    ## first parent:
    my $parent = $nodes_hash{$taxid};
    my $result;

    ## return "unassigned" if hit has no valid taxid
    if ($parent !~ m/\d+/) {
      $result = "unassigned";
      return $result;
    }

    ## recurse the tree:
    while (1) {
      if ($parent == $walk_to) {
        $result = "ingroup"; ## is ingroup
        last;
      } elsif ($parent == 1) {
        $result = "outgroup"; ## root; i.e., the whole tree has been recursed without finding $threshold, therefore $taxid must reside in another part of the tax tree
        last;
      } elsif ($parent == 32644) {
        $result = "unassigned"; ## taxid for "unidentified"
        last;
      } elsif ($parent == 12908) {
        $result = "unassigned"; ## taxid for "unclassified sequences"
        last;
      } else { ## walk up the tree!
        $parent = $nodes_hash{$parent};
      }
    }
    return $result;
}

sub tax_walk_to_get_rank_to_phylum {
  my $taxid = $_[0];
  my $parent = $nodes_hash{$taxid};
  my $parent_rank = $rank_hash{$parent};
  my ($phylum,$kingdom,$superkingdom) = ("undef","undef","undef");

  while (1) {
    if ($parent_rank eq "phylum") {
      $phylum = $names_hash{$parent};
      #print "Found phylum: $phylum\n";
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "kingdom") {
      $kingdom = $names_hash{$parent};
      #print "Found phylum: $kingdom\n";
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "superkingdom") {
      $superkingdom = $names_hash{$parent};
      #print "Found phylum: $superkingdom\n";
      last;
    } elsif ($parent == 1) {
      last;
    } else {
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
    }
  }
  my $result = join (";",$superkingdom,$kingdom,$phylum);
  $result =~ s/\s+/\_/g; ## replace spaces with underscores
  return $result;
}

sub tax_walk_to_get_rank_to_species {
  my $taxid = $_[0];
  my $parent = $nodes_hash{$taxid};
  my $parent_rank = $rank_hash{$parent};
  my ($species,$genus,$family,$order,$class,$phylum,$kingdom,$superkingdom) = ("undef","undef","undef","undef","undef","undef","undef","undef");

  while (1) {
    if ($parent_rank eq "species") {
      $species = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "genus") {
      $genus = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "family") {
      $family = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "order") {
      $order = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "class") {
      $class = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "phylum") {
      $phylum = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "kingdom") {
      $kingdom = $names_hash{$parent};
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
      next;
    } elsif ($parent_rank eq "superkingdom") {
      $superkingdom = $names_hash{$parent};
      last;
    } elsif ($parent == 1) {
      last;
    } else {
      $parent = $nodes_hash{$parent};
      $parent_rank = $rank_hash{$parent};
    }
  }
  my $result = join (";",$superkingdom,$kingdom,$phylum,$class,$order,$family,$genus,$species);
  $result =~ s/\s+/\_/g; ## replace spaces with underscores
  return $result;
}

sub log10 {
    my $n = shift;
    return log($n)/log(10);
}

sub percentage {
    my $numerator = $_[0];
    my $denominator = $_[1];
    my $places = "\%.2f"; ## default is two decimal places
    if (exists $_[2]){$places = "\%.".$_[2]."f";};
    my $float = (($numerator / $denominator)*100);
    my $rounded = sprintf("$places",$float);
    return $rounded;
}

sub commify {
    my $text = reverse $_[0];
    $text =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;
    return scalar reverse $text;
}
