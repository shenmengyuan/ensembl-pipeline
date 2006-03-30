#!/usr/local/ensembl/bin/perl -w

use strict;

#original version cDNA_update.pl for human cDNAs
#adapted for use with mouse cDNAs - Sarah Dyer 13/10/05
#uses new polyAclipping, stop list for gene trap cdnas (gss) and cdnas which hit too many times (kill list)

#will make three different logic names, eg mouse_cDNA_update, mouse_cDNA_update_2 and mouse_cDNA_update_3
#mouse_cDNA_update_2 and mouse_cDNA_update_3 are the same 

#mouse jobs can run in BatchQueue normal, human needs BatchQueue long

=pod

=head1 NAME

cDNA_setup

Procedure for getting the latest cDNAs aligned to an existing build
in an automated fashion.

=head1 SYNOPSIS / OPTIONS

  A. Fill in config variables, start script with argument 'prepare':
     "perl cDNA_update.pl prepare".
     If there is a new assembly, some sequence files (for human: DR52/DR53)
     might have to be adjusted (automatically, of course) and they will have
     to be pushed across the farm. The previous files should be removed
     before this! Please mail systems about these two things.
  B. Start script again with argument 'run' to start the pipeline.
  B. Check the results by comparing them to the previous alignment
     by calling "perl cDNA_update.pl compare"
  C. Start script again after finishing the pipeline run to clean up:
     "perl cDNA_update.pl clean", removing tmp files, etc.

=head1 DESCRIPTION

This is a set-up script for generating new cDNA alignments as an isolated step of the
build process with the Ensembl pipeline. We re using the current build as a basis to add
the latest cDNA information as an additional track. This is done using exonerate in
the pipeline, fasta files and repeat-masked genome files.
The configuration variables at the beginning of the script must ALL be filled in.
The whole process usually finishes in ~24h if there are no complications.
The results are dna_align_features in an ESTGENE-type database.
Use the clean-up option when finished to leave the system in the original state.
Check out the latest code to match the database to be updated, for example:
   cvs co -r branch-ensembl-32 ensembl
   cvs co -r branch-ensembl-32 ensembl-pipeline
   cvs co -r branch-ensembl-32 ensembl-analysis

The steps the script performs:
  1. config_setup: check config variables & files
  2. DB_setup: partly copy current db (PIPELINE database),
     insert analysis etc., create TARGET database, synchronise
  3. fastafiles: get & read input files
  4. chop off the polyA tails and chunk the fasta files into smaller pieces
  5. copy & modify the softmasked genome files if necessary:
     the coordinates given in the fasta headers need to be adjusted 
     according to the assembly table..
  6. run_analysis: run exonerate using the pipeline
  7. (optional) rerun cDNAs which did not align using different Exonerate parameters
  8. find_many_hits: identify those cDNAs which aligned to many places in the genome
  9. why_cdnas_missed: compile a list of reasons why hits were rejected

 10. comparison: health-check by comparing the results to previous alignments
     quicker version: get number of alignments for each chromosome from previous
     and new db version.
     extended version: look for new hits, track missing hits.
 11. cleanup: post-process result DB, restore config files, remove tmp files and dbs

What YOU will need to do:
  1. Fill in the config variables in this script (just below this).
  2. Check for the existance of two additional programs needed:
       fastasplit (splitting a fasta file into a number of chunks)
       polyA_clipping (removing poly-A tails from sequences)
  3. Ask systems to push the genome files across the farm
     (after the prepare step) if necessary.
  4. Run it; check the set-up and re-run if there are errors.
  5. Check the results directly and by running 'compare'.
  6. Clean up any mess by running 'clean'.
  7. Hand over target-database (patch to new version if necessary).

If there is an error and the script dies, the original config files are restored
without removing the data files and databases, allowing the re-run of the script.
You might want to run only the config_setup function again, without having to re-fetch the 
fasta files and to re-build the db, etc.

The setup of scripts and databases runs for ~ 15 min, the exonerate pipeline needs
around 24 h for human cDNAs, depending on farm usage.
Change specifications manually in BatchQueue.pm and re-run the pipeline command 
if jobs fail or take too long:
  resource => 'select[mem>2500] rusage[mem=2500]',
  queue    => 'bugmem'

Run the healthchecks:
run-healthcheck.sh -d <user>_cDNA_update -output problem -species homo_sapiens -type cdna post_genebuild
and hand-over target db.

=head1 CONTACT

ensembl-dev@ebi.ac.uk

=cut

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# configuration variables, adjust to your needs:
# all directories without trailing '/'

# personal base DIR for ensembl perl libs
# expects to find directories 'ensembl' & 'ensembl-analysis' here
my $cvsDIR               = "";

# personal data dir (for temporary & result/error files)
my $dataDIR              = ""; 

# sequence data files, which are used for the update
# if in doubt, ask Hans where to find new files
my $vertrna              = "embl_vertrna-1";
my $vertrna_update       = "emnew_vertrna-1";
my $refseq               = "hs.fna"; #"mouse.fna"; 
my $sourceHost           = "cbi1";
my $sourceDIR            = "/data/blastdb";
my $assembly_version     = "NCBI36"; #"NCBIM35";
my $target_masked_genome = "/data/blastdb/Ensembl/Human/$assembly_version/genome/softmasked_dusted.fa";
#my $target_masked_genome = "/data/blastdb/Ensembl/Mouse/NCBIM35/genome/softmasked_dusted/toplevel_sequences.fa"; 
my $user 				 = "sd3";
my $host 				 = "cbi1";

#only needed if assembly will be modified 
#my $org_masked_genome    = "/data/blastdb/Ensembl/Human/".$assembly_version."/softmasked_dusted";
my $org_masked_genome    = ""; #only used with adjust assembly()  - not necessary for mouse

my $kill_list			 = $cvsDIR."/ensembl-pipeline/scripts/GeneBuild/cDNA_kill_list.txt";
my $gss				     = "/nfs/acari/sd3/perl_code/ensembl-personal/sd3/mouse_cdna_update/gss_acc.txt";

# external programs needed (absolute paths):
my $fastasplit           = "/nfs/acari/searle/progs/fastasplit/fastasplit";
my $polyA_clipping       = "/ecs4/work3/sd3/ensembl-pipeline/scripts/EST/new_polyA_clipping.pl";
my $findN_prog 			 = "/ecs4/work3/sd3/ensembl-pipeline/scripts/cDNA_update/find_N.pl";
my $reasons_prog		 = "/ecs4/work3/sd3/ensembl-pipeline/scripts/cDNA_update/why_cdnas_didnt_hit.pl";

# db parameters
#admin rights required
my $WB_DBUSER            = "";
my $WB_DBPASS            = "";
# reference db (current build)
my $WB_REF_DBNAME        = "sd3_homo_sapiens_36_ref"; 
my $WB_REF_DBHOST        = "ecs2"; 
my $WB_REF_DBPORT        = "3362"; 
# new source db (PIPELINE)
my $WB_PIPE_DBNAME       = $ENV{'USER'}."_human_0306_cDNA_pipe";
my $WB_PIPE_DBHOST       = "ecs1b";
my $WB_PIPE_DBPORT       = "3306";
# new target db (ESTGENE)
my $WB_TARGET_DBNAME     = $ENV{'USER'}."_human_0306_cDNA_update";
my $WB_TARGET_DBHOST     = "ecs2";
my $WB_TARGET_DBPORT     = "3362";
# older cDNA db (needed for comparison only) - check schema is up to date!!!!!!
my $WB_LAST_DBNAME       = "sd3_homo_sapiens_cdna_38_35"; 
my $WB_LAST_DBHOST       = "ecs2";
my $WB_LAST_DBPORT       = "3362";  
# reference db (last build, needed for comparison only) 
my $WB_LAST_DNADBNAME    = "homo_sapiens_core_37_35j";
my $WB_LAST_DNADBHOST    = "ecs2"; 
my $WB_LAST_DNADBPORT    = "3365"; 

#use & adjust assembly exception sequences (human DR52 & DR53)
#set to 1 if you're looking at a new sequence assembly
my $adjust_assembly      = 0;

#set the species
my $common_species_name  = "human"; #"human"; #"mouse";
my $species	      = "Homo sapiens"; #"Homo sapiens"; #"Mus musculus";  

my $oldFeatureName     = "cDNA_update"; #for the comparison only



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#no changes should be necessary below this

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Data::Dumper;
#we need the Net::SSH module from somewhere:
use lib '/nfs/acari/fsk/perls/';
use Net::SSH qw(sshopen2);

my $newFeatureName     = "cDNA_update"; #the analysis name!
#when comparing to a previously updated cdna db $oldFeatureName = $newFeatureName
my %saved_files;
my $cmd;
my $status;
#temp. dirs & files:
my $config_file        = $cvsDIR."/ensembl-pipeline/scripts/cDNA_update/config_files.txt";
my $newfile            = "cdna_update";
my $configDIR          = $dataDIR."/configbackup";
my $chunkDIR           = $dataDIR."/chunks";
my $outDIR             = $dataDIR."/output";
my $masked_genome      = $target_masked_genome;
my $submitName         = "SubmitcDNAChunk";

my %configvars      = (
	 "cvsDIR" => $cvsDIR,
	 "dataDIR" => $dataDIR,
	 "chunkDIR" => $chunkDIR,
	 "outDIR" => $outDIR,
	 "vertrna" => $vertrna,
	 "vertrna_update" => $vertrna_update,
	 "refseq" => $refseq,
	 "configDIR" => $configDIR,
	 "sourceDIR" => $sourceDIR,
	 "newfile" => $newfile,
	 "config_file" => $config_file,
	 "masked_genome" => $masked_genome,
	 "fastasplit" => $fastasplit,
	 "polyA_clipping" => $polyA_clipping,
	 "WB_DBUSER" => $WB_DBUSER,
	 "WB_DBPASS" => $WB_DBPASS,
	 "WB_REF_DBNAME" => $WB_REF_DBNAME,
	 "WB_REF_DBHOST" => $WB_REF_DBHOST,
	 "WB_REF_DBPORT" => $WB_REF_DBPORT,
	 "WB_PIPE_DBNAME" => $WB_PIPE_DBNAME,
	 "WB_PIPE_DBHOST" => $WB_PIPE_DBHOST,
	 "WB_PIPE_DBPORT" => $WB_PIPE_DBPORT, 
     "WB_TARGET_DBNAME" => $WB_TARGET_DBNAME,
	 "WB_TARGET_DBHOST" => $WB_TARGET_DBHOST,
	 "WB_TARGET_DBPORT" => $WB_TARGET_DBPORT,
	 "newFeatureName" => $newFeatureName,
);


#fasta chunk specifications:
my $chunknum        = 4300;   #1500 for mouse, 4300 for human otherwise get AWOL jobs in first run
my $maxseqlength    = 17000;
my $tmp_masked_genome  = $dataDIR."/genome";
#program specifications:
my $program_name    = "exonerate";
my $program_version = "0.9.0";
my $program_file    = "/usr/local/ensembl/bin/exonerate-0.9.0";
my $module_name     = "Exonerate2Genes";
my $ans             = "";
my $num_missing_cdnas = 0;
my $rerun_flag = 0;

my $option = $ARGV[0];
if(!$option or ($option ne "prepare" and $option ne "run" and $option ne "clean" and $option ne "compare")){
   exec('perldoc', $0);
   exit 1;
}
if($option eq "prepare"){
  print "\nstarting cDNA-update procedure.\n";

  config_setup();

  print "\nGet fasta files?(y/n) ";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
    if(! fastafiles() ){ unclean_exit(); }

    if($adjust_assembly){
      adjust_assembly();
    }

  }

  print "\nset-up the databases?(y/n) ";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
    if(! DB_setup()   ){ unclean_exit(); }
    print "\n\nFinished setting up the analysis.\n";

    if($adjust_assembly){
      print "The genome files' directory will have to be distributed across the farm!\n".
	    "SOURCE PATH: ".$tmp_masked_genome."\nTARGET PATH: ".$target_masked_genome."\n\n";
    }

  }

}
elsif($option eq "run"){
  
  
  print "\nDo we need to set re-set the configs?(y/n) ";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
    config_setup()
  }

  run_analysis();

  find_missing_cdnas();
  
  print "\n$num_missing_cdnas have not aligned to the genome.\n".
  		"Would you like to rerun these cdnas with adjusted Exonerate parameters:\n".
  		"\tmax_intron = 400,000 and\n".
  		"\tsoftmasktarget = FALSE? (y/n) ";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
	$rerun_flag = 1;
	
	#change the logic_name and directories:
	$newFeatureName = $newFeatureName."_2"; #to show different params
	$configvars{"newFeatureName"} = $newFeatureName;
	$chunkDIR           = $dataDIR."/chunks2";
	$configvars{"chunkDIR"} = $chunkDIR;
	$outDIR             = $dataDIR."/output2";
	$configvars{"outDIR"} = $outDIR;
	
	config_setup();
	
    remake_fasta_files();


	print "\nreset the databases?(y/n) ";
	chomp($ans = <STDIN>);
	if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
		$rerun_flag = 1;
		if(! DB_setup()   ){ unclean_exit(); }
		print "\n\nFinished setting up the analysis.\n";


	}
	
	run_analysis();
	
  }	
  
  print "checking for AWOL jobs...\n";
  chase_jobs();
  
  print "Would you like to check for cDNAs which have hit many places in the genome?(y/n)";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
	  find_many_hits();
  }

  print "Would you like to make the list of reasons why cDNAs have not aligned?(y/n)";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){

	  why_cdnas_missed();

  }
  
  print "you should now change the analysis_ids of the cdnas in your database so that they ". 
  		"all have the same logic name, otherwise the comparison script won't work;\n".
		"you will need to change both the gene and dna_align_feature tables\n";

}
elsif($option eq "clean"){
  print "\ncleaning up after cDNA-update.\n";

  clean_up(0);
}
elsif($option eq "compare"){
  print "\nrunning checks after cDNA-update.\n".
        "checking through alignments & genes.\n";

  check_vars();
  compare();
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# Write required config files for analysis.
# Stores content and location of original files for later restoration.
# The required config values are written into placeholders in the config skeleton file (config_files.txt)
#  using the variables defined above.

sub config_setup{

  $status = 0;
  my $filecount = 0;
  my ($header, $filename, $path);
  #set env var to avoid warnings
  if(!defined $ENV{"OSTYPE"} ){
    $ENV{"OSTYPE"} = "";
  }
  #import function, to be included in all config files
  my $import_sub = '
  sub import {
    my ($callpack) = caller(0);
    my $pack = shift;
    my @vars = @_ ? @_ : keys(%Config);
    return unless @vars;
    eval "package $callpack; use vars qw(".
      join(\' \', map { \'$\'.$_ } @vars) . ")";
    die $@ if $@;
    foreach (@vars) {
      if (defined $Config{ $_ }) {
        no strict \'refs\';
	*{"${callpack}::$_"} = \$Config{ $_ };
      }else {
	die "Error: Config: $_ not known\n";
      }
    }
  }
  1;
  ';

  check_vars();

  #check existence of source databases
  if(!connect_db($WB_REF_DBHOST, $WB_REF_DBPORT, $WB_REF_DBNAME, $WB_DBUSER, $WB_DBPASS)){
    die "could not find $WB_REF_DBNAME.";
  }

  #go through config info to create defined files,
  #back-up the original, write version with filled-in variables
  open(RP, "<", "$config_file") or die("can't open config file definitions $config_file");
  local $/ = '>>';
  <RP>;
  while(my $content = <RP>){
    #get specific config-file name
    $content  =~ s/([\w\/_\-\.]+)\n//;
    $header   = $1;
    $header   =~ m/(.+\/)([\w\._\-]*)$/g;
    $path     = $1;
    $filename = $2;
    $content  =~ s/>>//;
    #replace variables in config file
    foreach my $configvarref (keys %configvars){
      $content =~ s/\<$configvarref\>/$configvars{$configvarref}/g;
    }
	
	#if rerunning seqs change Exonerate options:
	if (($filename=~/Exonerate2Genes/ ) && ($rerun_flag == 1 )){
		$content =~s/-verbosity => 0/-verbosity => 1/; #because only interested in those which don't align after new parameters
		$content =~s/--softmasktarget TRUE/--maxintron 400000 --bestn 10 --softmasktarget FALSE/;
	}	
	
    #backup file if exists
    if(-e $cvsDIR."/".$header){
      $cmd = "mv ".$cvsDIR."/".$header." ".$configDIR."/".$filecount;
      if(system($cmd)){
		die "could not backup config file $header.\n";
      }
    }
    
	#store file location
    $saved_files{$filecount} = $header;
	
	#write modified file
    $filename = $cvsDIR."/".$path.$filename;
    open(WP, ">", $filename) or die("can't create new config file $filename.\n");
    print WP $content."\n".$import_sub;
    close WP;
    $filecount++;
  }
  close(RP);

  #save data dump with config paths
  $Data::Dumper::Purity = 1;
  open(WP, "> config_paths.perldata") or die "\ncan't create file for data dumping!\n";
  print WP Data::Dumper->Dump([\%saved_files], ['*saved_files']);
  close(WP);
  $/ = "\n";
  print "created backup of current config files, new config files written.\n";
}


#check files & directories, create if necessary

sub check_vars{
  foreach my $configvarref (keys %configvars){
    if(!$configvarref){ die "please define all configuration variables! [$configvarref]\n"; }
    if($configvarref =~ m/.+DIR.*/){
	  if(!-e $configvars{$configvarref}){
		if(system("mkdir $configvars{$configvarref}")){ die "could not create directory! [$configvars{$configvarref}]\n"; }
      }
      if(!-r $configvars{$configvarref}){ die "directory not accessible! [$configvars{$configvarref}]";}
    }
  }
}


# delete old content if any for a given directory
# (recursively, as some tmp-dir get pretty crowded...)

sub checkdir{
  my $dirname = shift;
  my $option  = shift;
  #go through dirs recursively
  unless (opendir(DIR, $dirname)) {
    closedir(DIR);
    print "\ncan't open $dirname.\n";
    return 0;
  }
  my @files = grep (!/^\.\.?$/, readdir(DIR));
  foreach my $file (@files) {
    if( -f "$dirname/$file") {
      system("rm $dirname/$file");
    }
    if( -d "$dirname/$file") {
      checkdir("$dirname/$file");
    }
  }
  closedir(DIR);
  if(!$option){
    eval{ system("rmdir $dirname"); };
  }
  return 1;
}


# fetch fasta files, combine them, chop them up

sub fastafiles{
	$status = 0;
	my %EMBL_ids;
	my $header;
	my $vertrna_ver     = 1;
	my $vertrna_upd_ver = 1;
	my $refseq_ver      = 1;
	my $update          = 0; #set to 1 if want to redo clipping and chunks regardless of changes in vertna etc
	my @filestamp;

	eval{
	    #check file versions, copy only if changed
		$cmd  = "cd $sourceDIR; ls -n ".$vertrna." ".$vertrna_update." ".$refseq;
		sshopen2("$user\@$host", *READER, *WRITER, "$cmd") || die "ssh: $!";
		while(<READER>){
			@filestamp = split(" ", $_);
			my $stampA = join("-", @filestamp[5..7]);
			$cmd  = "cd ".$dataDIR."; "."ls -n ".$filestamp[8];
			@filestamp = split(" ", `$cmd`);
			my $stampB = join("-", @filestamp[5..7]);
			if($stampA eq $stampB){
			    #no changes...
				if($filestamp[8] eq $vertrna){ $vertrna_ver = 0; }
				elsif($filestamp[8] eq $vertrna_update){ $vertrna_upd_ver = 0; }
				elsif($filestamp[8] eq $refseq){ $refseq_ver = 0; }
			}
		
	   }    
       close(READER);
       close(WRITER);
       #copy files
       if($vertrna_ver){
    	 $cmd = "scp -p " . $sourceHost.":".$sourceDIR."/".$vertrna . " " . $dataDIR."/".$vertrna;
    	 $status += system($cmd);
       }
       if($vertrna_upd_ver){
    	 $cmd = "scp -p " . $sourceHost.":".$sourceDIR."/".$vertrna_update . " " . $dataDIR."/".$vertrna_update;
    	 $status += system($cmd);
       }
       if($refseq_ver){
    	 $cmd = "scp -p " . $sourceHost.":".$sourceDIR."/".$refseq . " " . $dataDIR."/".$refseq;
    	 $status += system($cmd);
       }
       if($status){ die("Error while copying files.\n") }
       print "copied necessary files.\n";

       if($vertrna_upd_ver or $vertrna_ver or $refseq_ver){
            $update = 1;
    		#get entries for species of interest, combine base file & update file
    		#read update file
    		local $/ = "\n>";
    		open(RP, "<", $dataDIR."/".$vertrna_update) or die("can t read $vertrna_update\n");
    		open(WP, ">", $dataDIR."/".$newfile) or die("can t create $newfile\n");
    		#<RP>;
    		while (my $entry = <RP>){
        		$entry =~s/^>//; #need this to include the first record when using $/='\n>'
				if($entry =~ m/$species/){
					#extract & save id
					$entry =~ s/^[\w\d]+\s([\w\.\d]+)\s.+\n{1}?/$1\n/;
					if(!$1){ die "\n$vertrna_update: unmatched id pattern:\n$entry\n"; }
					$EMBL_ids{$1} = 1;
					#re-write fasta entry
					$entry =~ s/\>//g;
					print WP '>'.$entry;
				}
    		}
    		close(RP);
    		print "read update EMBL file.\n";

    	    #read base file
    		open(RP, "<", $dataDIR."/".$vertrna) or die("can t read $vertrna\n");
    		#<RP>;
    		while (my $entry = <RP>){
        		$entry =~s/^>//; #need this to include the first record when using $/='\n>'
				if($entry =~ m/$species/){
					#extract & save id
					$entry =~ s/^[\w\d]+\s([\w\.\d]+).+\n{1}?/$1\n/;
					if(!$1){ die "\n$vertrna: unmatched id pattern:\n$entry\n"; }
					if( !defined($EMBL_ids{$1}) ){
	    				#add fasta entry for unchanged id
	    				$entry =~ s/\>//g;
	    				print WP '>'.$entry;
					}
				}
    		}
    		close(RP);
    		print "read base EMBL file.\n";

    		#read RefSeq file
    		open(RP, "<", $dataDIR."/".$refseq) or die("can t read $refseq.\n");
    		#<RP>;
    		while (my $entry = <RP>){
        		$entry =~s/^>//; #need this to include the first record when using $/='\n>'
				#we're not using 'predicted' XM entries for now
				if($entry =~ m/^gi.+ref\|(NM_.+)\| $species.*/){
				    $header = $1;
				}
				elsif($entry =~ m/^gi.+ref\|(NR_.+)\| $species.*/){
				    $header = $1;
				}
				else{
				    next;
				}
				$entry =~ s/\>//g;
				if($header){
				  #reduce header to accession number
				  $entry =~ s/^gi.+\n{1}?/$header\n/g;
				  print WP '>'.$entry;
				}
    		}
    		print "read RefSeq file.\n";
    		close(RP);
    		close(WP);
    		local $/ = "\n";
    	}    

		#read in the seq_ids from the kill_list;
		open(LIST, "<", $kill_list) or die("can't open kill list $kill_list");
		my %kill_list;
		while (<LIST>){
			my @tmp = split/\s+/, $_;
			$kill_list{$tmp[0]} = 1;
		}
		close LIST;

		open(LIST, "<", $gss) or die("can't open gss list $gss");
		my %gss;
		while (<LIST>){
			my @tmp = split/\s+/, $_;
			$gss{$tmp[1]} = 1;
		}
		close LIST;

		#go through file removing any seqs which appear on the kill list
		local $/ = "\n>";
		my $newfile2 = $newfile.".seqs";
		open(SEQS, "<", $dataDIR."/".$newfile) or die("can't open seq file $newfile");  
		open(OUT, ">", $dataDIR."/".$newfile2) or die("can't open seq file $newfile2"); 
		while(<SEQS>){
			s/>//g;

			my @tmp = split/\n/, $_;
			my $acc; #store the accession number
			if ($tmp[0]=~/(\w+)\./){
				$acc = $1;
			}
			if ((!exists $kill_list{$tmp[0]}) && !exists $gss{$acc}){
				print OUT ">$_";
			}
		}
		local $/ = "\n";
		close OUT;
		close SEQS;

    	if($update){
    		#clip ployA tails
			print "performing polyA clipping...\n";
			my $newfile3 = $dataDIR."/".$newfile2.".clipped";
    		$cmd = "perl ".$polyA_clipping ." ".$dataDIR."/".$newfile2." ".$newfile3;
			#$cmd = "$polyA_clipping -mRNA ".$dataDIR."/".$newfile2." -out ".$newfile3." -clip"; #old polyAclipping command
    		if(system($cmd)){
			   die("couldn t clip file.$@\n");
    		}

    		#split fasta files, store into CHUNKDIR
    		print "splitting fasta file.\n";
    		$cmd = "$fastasplit $newfile3 $chunknum $chunkDIR";
    		if(system($cmd)){
	  		  die("couldn t split file.$@\n");
    		}

    		#isolate biggest sequences
    		check_chunksizes();

    		print "\nchopped up file.\n";
		}
	};   
	if($@){
    	print STDERR "\nERROR: $@";
    	return 0;
	}
	-return 1;
}

sub remake_fasta_files{

	#have already made the sequence file from the previously clipped seqs: 
	#just need to rechunk it:	  
	
	my $file = $dataDIR."/missing_cdnas.fasta"; #from sub find_missing_cdnas
	
	#how many files do we want? automatically adjust chunk_num, don't wnat >20 seqs/file because softmasktarget = false
	my $chunk_num = int ($num_missing_cdnas / 20);
	
	#split fasta files, store into new CHUNKDIR
    print "splitting new fasta file.\n";

    $cmd = "$fastasplit $file $chunk_num $chunkDIR";
    if(system($cmd)){
		die("couldn t split file.$@\n");
    }

    #isolate biggest sequences
    check_chunksizes();

    print "\nchopped up file.\n";
}


#adjust sequence files for assembly-exceptions
#currently looks for DR*.fa files

sub adjust_assembly{
  my $filename;
  #move original genome files to defined temporary location
  if(! -e $tmp_masked_genome){
    if(system("mkdir $tmp_masked_genome")){ die "could not create directory! [$tmp_masked_genome]\n"; }
  }
  $cmd = 'ln -s '.$org_masked_genome.'/* '.$tmp_masked_genome.'/';
  if(system($cmd)){
    die("couldn t copy masked genome files.$@\n");
  }
  #get the correct location of DR-assembly pieces
  my $db  = db_connector($WB_PIPE_DBHOST, $WB_PIPE_DBPORT, $WB_PIPE_DBNAME, 'ensro');
  my $sql = 'select s.name, s.seq_region_id, ae.seq_region_start, ae.seq_region_end '.
            'from seq_region s, assembly_exception ae where s.seq_region_id=ae.seq_region_id '.
	    'and s.name like "DR%";';
  my $sth = $db->prepare($sql) or die "sql error!";
  $sth->execute();
  while( my ($name, $seq_region_id, $seq_region_start, $seq_region_end) = $sth->fetchrow_array ){
    #read original file (link)
    $filename = $tmp_masked_genome."/".$name.".fa";
    open(FASTAFILE, "<$filename") or die("cant open fasta file $filename.");
    my $headerline = <FASTAFILE>;
    $headerline =~ s/^\>(\w+)\:([\w\d]*)\:([\w\d]*)\:(\d+)\:(\d+)\:(.+)//;
    $headerline = ">".$1.":".$2.":".$3.":".$seq_region_start.":".$seq_region_end.":".$6;
    local $/ = '';
    my $seq = <FASTAFILE>;
    local $/ = '\n';
    close(FASTAFILE);
    #remove file (link)
    $cmd = 'rm '.$filename;
    if($cmd){ die 'can t remove link '.$filename.'!'; }
    #write modified file
    open(FASTAFILE, ">$filename") or die("cant open fasta file $filename for writing.");
    print FASTAFILE $headerline."\n";
    print FASTAFILE $seq;
    close(FASTAFILE);
  }
  #create README for new genome directory
  my $date = "";
  my ($day, $month, $year) = (localtime)[3,4,5];
  my $datestring = printf("%04d %02d %02d", $year+1900, $month+1, $day);
  my $readme = $masked_genome."/README";
  open(README, ">$readme") or die "can t create README file.";
  
        if ($common_species_name eq "human"){
		print README "Directory ".$target_masked_genome."\n\n".
		"These are the softmasked dusted genome files from human ".$assembly_version.
		" assembly with two small modifications:\nThe coordinates of the DR52 & DR53 ".
		"contigs were adjusted according to the assembly table of the database ".
		$WB_REF_DBNAME.
	        ".\nThey are used for the cDNA-update procedure to produce an up-to-date cDNA track ".
		"every month.\nCreated by ".$ENV{USER}." on ".$datestring.".\n\n";
	}else{
		print README "Directory ".$target_masked_genome."\n\n".
		"These are the softmasked dusted genome files from " .$common_species_name. "  ".$assembly_version.
		" assembly. \nThey are used for the cDNA-update procedure to produce an up-to-date cDNA track ".
		"every month.\nCreated by ".$ENV{USER}." on ".$datestring.".\n\n";
	}
  close(README);
}


#find the really big sequences & put them into separate chunks

sub check_chunksizes{
  local $/ = '>';
  my $allseqs;
  my $file;
  my $toolongs;
  my $seqname;
  my $newfile;

  unless ( opendir( DIR, $chunkDIR ) ) {
    die "can t read $chunkDIR";
  }
  foreach( readdir(DIR) ){
    if(($_ =~ /^\.+$/) or ($_ =~ /^newchunk.+$/)){ next; }
      $file = $chunkDIR."/".$_;
      $toolongs = 0;
      $allseqs = "";

      open(CHUNKFILE, "<$file") or die("can t open file $file.");
      <CHUNKFILE>; #skipping the first one as it just contains ">"

      while(my $seq = <CHUNKFILE>){
    	$seq =~ s/\>//;
    	$seq =~ m/(.+)\n/;
    	$seqname = $1;
    	if(length($seq) > $maxseqlength){
		  print "\nTOO LONG: $seqname";
		  if(!$toolongs){
			$toolongs = 1;
		  }
		  $newfile = $chunkDIR."/newchunk_".$seqname;
		  open(NEWFILE, ">$newfile") or die "can t create new fasta file $newfile!";
		  print NEWFILE ">".$seq;
		  close(NEWFILE);
    	}
    	else{
		  $allseqs .= ">".$seq;
    	}
      }
      close(CHUNKFILE);

    if($toolongs){
      open(CHUNKFILE, ">$file") or die("can t open file $file.");
      print CHUNKFILE $allseqs;
      close(CHUNKFILE);
    }
  }
  closedir(DIR);
  local $/ = "\n";
}


# prepare required databases: pipe DB, result DB,
# fill required tables with data

sub DB_setup{
  $status = 0;

  eval{
    
	if ($rerun_flag == 0){
	
		#create dbs, deleting if existing
    	$status  = system("mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e\"DROP DATABASE IF EXISTS $WB_PIPE_DBNAME;\"");
    	if($status && $status != 256){ die("couldnt drop old database $WB_PIPE_DBNAME!\n"); }
    	$status  = system("mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e\"CREATE DATABASE $WB_PIPE_DBNAME;\"");
    	$status += system("mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_PIPE_DBNAME < ".$cvsDIR."/ensembl/sql/table.sql");
    	$status += system("mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_PIPE_DBNAME < ".$cvsDIR."/ensembl-pipeline/sql/table.sql");
    	print ".";
    	$status  = system("mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e\"DROP DATABASE IF EXISTS $WB_TARGET_DBNAME;\"");
    	if($status && $status != 256){ die("couldnt drop old database $WB_TARGET_DBNAME!\n"); }
    	$status += system("mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e\"CREATE DATABASE $WB_TARGET_DBNAME;\"");
    	$status += system("mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_TARGET_DBNAME < ".$cvsDIR."/ensembl/sql/table.sql");
    	print ".";
    	#copy defined db tables from current build #removed analysis table
    	$cmd = "mysqldump -u$WB_DBUSER -p$WB_DBPASS -h$WB_REF_DBHOST -P$WB_REF_DBPORT -t $WB_REF_DBNAME".
    	  " assembly attrib_type coord_system exon exon_stable_id exon_transcript gene gene_stable_id meta meta_coord".
    	  " assembly_exception seq_region seq_region_attrib transcript transcript_stable_id translation translation_stable_id".
    	  " > ".$dataDIR."/import_tables.sql";
    	$status += system($cmd);
    	print ".";
    	$cmd = "mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e  '".
		   "DELETE FROM analysis; DELETE FROM assembly; DELETE FROM attrib_type; DELETE FROM coord_system;" .
        	   "DELETE FROM exon; DELETE FROM exon_stable_id; DELETE FROM exon_transcript; DELETE FROM gene; ".
		   "DELETE FROM gene_stable_id; DELETE FROM meta; DELETE FROM meta_coord;  DELETE FROM assembly; ".
        	   "DELETE FROM assembly_exception; DELETE FROM seq_region_attrib; DELETE FROM transcript; DELETE FROM transcript_stable_id; ".
        	   "DELETE FROM translation; DELETE FROM translation_stable_id; DELETE FROM assembly_exception;' $WB_PIPE_DBNAME ";
    	$status += system($cmd);
    	print ".";
    	$status += system("mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_PIPE_DBNAME < ".$dataDIR."/import_tables.sql");
    	print ".";
    	#copy dna table from current build
    	$cmd = "mysqldump -u$WB_DBUSER -p$WB_DBPASS -h$WB_REF_DBHOST -P$WB_REF_DBPORT".
        	   " -t $WB_REF_DBNAME dna"." > ".$dataDIR."/import_tables2.sql";
    	$status += system($cmd);
    	print ".";
    	$cmd = "mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_PIPE_DBNAME < ".
            	$dataDIR."/import_tables2.sql";
    	$status += system($cmd);
    	print  ".";
		$cmd = "mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_TARGET_DBNAME -e \"LOAD DATA INFILE \'$cvsDIR".
		       "/ensembl/misc-scripts/external_db/external_dbs.txt\' INTO TABLE external_db\"";
		$status += system($cmd);
		print  ".";
		$cmd = "mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_TARGET_DBNAME -e \"LOAD DATA INFILE \'$cvsDIR".
		       "/ensembl/misc-scripts/unmapped_reason/unmapped_reason.txt\' INTO TABLE unmapped_reason\"";
		$status += system($cmd);	   
		
		if($status){ die("couldnt create databases!\n"); }
    	print "created databases.\n";

	}else{
		#if rerunning without rebuilding databases - clear out jobs tables first:
    	$cmd = "mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e  '".
	    "DELETE FROM job; DELETE FROM job_status; DELETE FROM rule_goal; DELETE FROM rule_conditions;" .
        "DELETE FROM input_id_analysis; DELETE FROM input_id_type_analysis; DELETE from analysis where logic_name = \"$newFeatureName\";".
	    "DELETE from analysis where logic_name = \"$submitName\";' $WB_PIPE_DBNAME ";
    	$status += system($cmd);
   } 
	
	#insert analysis entries
    $cmd = "perl ".$cvsDIR."/ensembl-pipeline/scripts/add_Analysis ".
           " -dbhost $WB_PIPE_DBHOST -dbname $WB_PIPE_DBNAME -dbuser $WB_DBUSER -dbpass $WB_DBPASS".
           " -logic_name $newFeatureName -program $program_name -program_version $program_version".
	   " -program_file $program_file -module $module_name".
	   " module_version 1 -gff_source Exonerate -gff_feature similarity -input_id_type FILENAME";
    $status += system($cmd);
    $cmd = "perl ".$cvsDIR."/ensembl-pipeline/scripts/add_Analysis ".
           " -dbhost $WB_PIPE_DBHOST -dbname $WB_PIPE_DBNAME -dbuser $WB_DBUSER -dbpass $WB_DBPASS".
           " -logic_name $submitName -module dummy -input_id_type FILENAME";
    $status += system($cmd);
    $cmd = "perl ".$cvsDIR."/ensembl-pipeline/scripts/RuleHandler.pl".
           " -dbhost $WB_PIPE_DBHOST -dbname $WB_PIPE_DBNAME -dbuser $WB_DBUSER -dbpass $WB_DBPASS".
	   " -insert -goal $newFeatureName -condition $submitName";
    $status += system($cmd);
    $cmd = "perl ".$cvsDIR."/ensembl-pipeline/scripts/make_input_ids".
           " -dbhost $WB_PIPE_DBHOST -dbname $WB_PIPE_DBNAME -dbuser $WB_DBUSER -dbpass $WB_DBPASS".
           " -file -dir $chunkDIR -logic_name $submitName";
    $status += system($cmd);
    if($status){ die("Error while setting up the database.\n") }
    print "database set up.\n";
    #copy analysis entries (and others, just to make sure)
    $cmd = "mysqldump -u$WB_DBUSER -p$WB_DBPASS -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -t $WB_PIPE_DBNAME".
           " analysis assembly assembly_exception attrib_type coord_system meta meta_coord seq_region seq_region_attrib ".
           "> ".$dataDIR."/import_tables3.sql";
    $status += system($cmd);
    $cmd = "mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e '".
           "DELETE FROM analysis; DELETE FROM assembly; DELETE FROM attrib_type; DELETE FROM coord_system; ".
           "DELETE FROM meta; DELETE FROM meta_coord; DELETE FROM seq_region; DELETE FROM seq_region_attrib; ".
           "DELETE FROM assembly_exception;' $WB_TARGET_DBNAME";
    $status += system($cmd);

    $status += system("mysql -h$WB_TARGET_DBHOST -P$WB_TARGET_DBPORT -u$WB_DBUSER -p$WB_DBPASS $WB_TARGET_DBNAME < ".$dataDIR."/import_tables3.sql");
    if($status){ die("Error while synchronising databases.\n") }
    print "databases in sync.\n";
  };
  if($@){
    print STDERR "\nERROR: $@";
    return 0;
  }
  return 1;
}


# call rulemanager to start the exonerate run, leaving the set-up script

sub run_analysis{
  #running a test first
  print "\nRunning the test-RunnablDB first.\nPlease monitor the output.\nShould we start? (y/n)";
  my $ans = "";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
    #get one input id for testing
    my $db = db_connector($WB_PIPE_DBHOST, $WB_PIPE_DBPORT, $WB_PIPE_DBNAME, "ensro");
    my $sql = 'SELECT input_id FROM input_id_analysis i, analysis a WHERE i.analysis_id=a.analysis_id '.
              'AND a.logic_name="'.$submitName.'" LIMIT 1;';
    my $sth = $db->prepare($sql) or die "sql error getting an input-id!";
    $sth->execute();
    my ($input_id) = $sth->fetchrow_array;
    if(!$input_id){
      die "\nCould not get an input id from database!\nQuery used: $sql\n\n";
    }
    $cmd = "perl ".$cvsDIR."/ensembl-analysis/scripts/test_RunnableDB ".
           "-dbhost $WB_PIPE_DBHOST -dbport $WB_PIPE_DBPORT -dbuser $WB_DBUSER -dbpass $WB_DBPASS -dbname $WB_PIPE_DBNAME ".
	   "-input_id $input_id -logic_name $newFeatureName -verbose -nowrite";
    print $cmd."\n";
    system($cmd);
  }
  #start the real process
  print "\n\nShould we start the actual analysis? (y/n)";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
    $cmd = "perl ".$cvsDIR."/ensembl-pipeline/scripts/rulemanager.pl ".
           "-dbhost $WB_PIPE_DBHOST -dbport $WB_PIPE_DBPORT -dbuser $WB_DBUSER -dbpass $WB_DBPASS -dbname $WB_PIPE_DBNAME";
    print "\nSTARTING PIPELINE.\nusing the command:\n".$cmd."\n\nPlease monitor results/errors of the pipeline.\n\n";
    system($cmd);
  }
  else{
    print "\nProcess interrupted. Not running pipeline.\n\n";
  }
}

#identify cdnas which did not align to the genome:
sub find_missing_cdnas{

	#find all the cdnas which have hits in the database:
	my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(
						     -host    => $WB_TARGET_DBHOST,
						     -port    => $WB_TARGET_DBPORT,
						     -user    => $WB_DBUSER,
						     -dbname  => $WB_TARGET_DBNAME,
							 -pass	  => $WB_DBPASS
						    );

	my $sql = ("select distinct hit_name from dna_align_feature"); 			

	my $q1 = $db->dbc->prepare($sql) or die "sql error";
	$q1->execute();
	my (%cdna_hits);
	
	#make list of cdnas with hits in the database
	while (my $cdna = $q1->fetchrow_array){
		$cdna_hits{$cdna} = 1;
	}	

	#now go through clipped sequence file and extract those sequences which do not have any hits in the database

	open (OUT, ">".$dataDIR."/missing_cdnas.fasta") or die("can t open file missing_cdnas.fasta");
	local $/ = "\n>";
	my $cdna_file = $dataDIR."/".$newfile.".seqs.clipped";
	open(IN, "<$cdna_file") or die("can t open file $cdna_file.");
	while(<IN>){
		my $seq = $_;
		
		if ($seq=~/(\w+\.\d+)\n/){
			
			if(!exists $cdna_hits{$1}){
				$seq =~ s/>//g;
				print OUT ">$seq\n";
			}	
		}
	}			
	close IN;
	close OUT;
	
	$num_missing_cdnas = `grep ">" $dataDIR/missing_cdnas.fasta | wc -l`;
	chomp $num_missing_cdnas;
	return $num_missing_cdnas;
}

#run a check to see if there are any unfinished jobs in the database:
sub chase_jobs{

	#incase have skipped previous sections, reset variables:
	$rerun_flag = 1;
  	$chunkDIR = $dataDIR."/chunks2";
 

	my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(
						    	 -host    => $WB_PIPE_DBHOST,
						    	 -port    => $WB_PIPE_DBPORT,
						    	 -user    => $WB_DBUSER,
						    	 -dbname  => $WB_PIPE_DBNAME,
								 -pass	  => $WB_DBPASS
						    	);

	#want to find the list of input files which did not finish running in the db
	my $sql = ("select input_id from job as j, job_status as s where j.job_id = s.job_id && s.is_current = 'y'");			

	my $q1 = $db->dbc->prepare($sql) or die "sql error";
	$q1->execute();
	my %chunks;
	while (my $file = $q1->fetchrow_array){
		$chunks{$file} = 1;
	}	

	my $n = keys %chunks;
	
	if ($n){
		
		print "$n chunks did not finish\n";
		
		#store the chunks into a single file:
		open (OUT, ">".$dataDIR."/single_file.out") or die("can t open file single_file.out");
		open (LIST, ">".$chunkDIR."/went_awol.txt") or die("can t open file went_awol.txt"); #store the list incase need to rerun
		my $seq_count = 0;
		foreach my $file (keys %chunks){
			print LIST "$file\n";
			open IN, $chunkDIR."/".$file  or die "can't open ".$chunkDIR."/$file $!\n";

			while (<IN>){
				if ($_=~/>/){
					$seq_count++;
				}
				print OUT "$_";
			}
			close IN;
		}
		close OUT;
		close LIST;
		
		print "There were $seq_count cdnas in the files which didn't run\n";
		print "Would you like to try with smaller chunk files?(y/n)\n";
		my $ans = "";
		chomp($ans = <STDIN>);
  		if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
			print "please specify number of chunk files to make (maximum = 1 file per cdna): ";
			my $ans = "";
			chomp($ans = <STDIN>);
			if ($ans > $seq_count){
				print "this would give less than 1 sequence per file\n";
				exit;
			}elsif ($ans <= $n){
				print "this is the same number of chunk files as last time - it would be better to increase the number of files\n";
				exit;
			}else{
				if ($newFeatureName=~/_2/){
					$newFeatureName =~s/_2/_3/; #to show different run
				}else{
					$newFeatureName = $newFeatureName."_3"; #if have restarted from point after the second run
				}
				$configvars{"newFeatureName"} = $newFeatureName; 
				$chunkDIR           = $dataDIR."/chunks3";
				$configvars{"chunkDIR"} = $chunkDIR;
				$outDIR             = $dataDIR."/output3";
				$configvars{"outDIR"} = $outDIR;
			
				#check that the new exonerate parameters are set
				config_setup();
				
				$chunknum = $ans;
				$chunkDIR = $dataDIR."/chunks3";
				print "splitting into $chunknum chunks.\n";

    			$cmd = "$fastasplit $dataDIR/single_file.out $chunknum $chunkDIR";
    			if(system($cmd)){
					die("couldn t split file.$@\n");
    			}

    			#isolate biggest sequences
    			check_chunksizes();

    			print "\nchopped up file.\n";
	
				print "\nreset the databases?(y/n) ";
				chomp($ans = <STDIN>);
				if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
					$rerun_flag = 1;
					if(! DB_setup()   ){ unclean_exit(); }
					print "\n\nFinished setting up the analysis.\n";

				}
				run_analysis();
				
				print "you should check for any AWOL jobs now, hopefully there won't be any \n";
			}
		}	
	}	
}

#check the database for those cDNAS which hit many times - might be worth adding these to the kill list
#depending on what they are eg LINEs
sub find_many_hits{
	#mysql queries involving temporary tables 
	my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(
						    	 -host    => $WB_TARGET_DBHOST,
						    	 -port    => $WB_TARGET_DBPORT,
						    	 -user    => $WB_DBUSER,
						    	 -dbname  => $WB_TARGET_DBNAME,
								 -pass	  => $WB_DBPASS
						    	);

		
	#make a table containing each transcript matchign a cDNA
	my $sql1 = ("create temporary table tmp1 ".
		"select hit_name, exon_transcript.transcript_id ".
		"from dna_align_feature, supporting_feature, exon_transcript ".
		"where dna_align_feature_id = feature_id and supporting_feature.exon_id = exon_transcript.exon_id ".
		"group by hit_name, exon_transcript.transcript_id");		

	my $q1 = $db->dbc->prepare($sql1) or die "sql error 1";
	$q1->execute();
	
	#group these to find the number of hits per cDNA
	my $sql2 = ("create temporary table tmp2 select hit_name, count(*) as hits from tmp1 group by hit_name");		

	my $q2 = $db->dbc->prepare($sql2) or die "sql error 2";
	$q2->execute();
	
	#examine those which hit more than 20 places
	my $sql3 = ("select * from tmp2 where hits > 20 order by hits desc");		

	my $q3 = $db->dbc->prepare($sql3) or die "sql error 3";
	$q3->execute();
	my $many_hits_flag = 0;
	while (my ($cdna, $hits)  = $q3->fetchrow_array){
		print "$cdna\t$hits\n";
		$many_hits_flag = 1;
	}	
	
	if ($many_hits_flag){
		print "It might be worth investigating these sequences to see whether these are likely to be genuine hits.\n".
		"If we don't want them in the database you should add them to the kill list\n";
	}
}

#run the script to parse output from ExonerateTranscriptFilter to identify reasons for failures
sub why_cdnas_missed{
	#first need to create no_hits.txt
	#make a file containing all of the relevant lines from ExonerateTranscriptFilter.pm outputs
	my @output = ("output2", "output3");
	my $file = $dataDIR."/failed_hits.out";
	
	open (OUT, ">$file") or die("can t open file $file"); #to empty it
	close OUT;
	for my $output (@output){
		`find $dataDIR/$output/. | xargs -l1 grep "rpp" >> $file`;
		`find $dataDIR/$output/. | xargs -l1 grep "only" >> $file`;
		`find $dataDIR/$output/. | xargs -l1 grep "reject" >> $file`;
		`find $dataDIR/$output/. | xargs -l1 grep "max_coverage" >> $file`;
	}

	#need to pass all the variables to the script:
    $cmd = "perl ".$reasons_prog.
           " -kill_list ".$kill_list." -gss ".$gss." -seq_file ".$dataDIR."/missing_cdnas.fasta -user ensro".
           " -host ".$WB_TARGET_DBHOST." -port ".$WB_TARGET_DBPORT." -dbname ".$WB_TARGET_DBNAME.
           " -species \"".$species."\" -vertrna ".$dataDIR."/".$vertrna." -refseq ".$dataDIR."/".$refseq.
           " -vertrna_update ".$dataDIR."/".$vertrna_update." -infile ".$dataDIR."/failed_hits.out".
		   " -outfile ".$dataDIR."/missing_cdnas.txt "."-findN_prog ".$findN_prog;

	#print "$cmd\n";
    if(system($cmd)){
		 warn " some error occurred when running why_cdnas_didnt_hit.pl!\n$cmd\n "; 
	}else{
		print "Reasons list made\n";
	}
}

# remove files and database leftovers after analysis,
# restore original config files

sub clean_up{
  my $option = shift;
  my $ans = "";
  $status = 0;
  #read data dump
  open(RP, "< config_paths.perldata") or $status = 1;
  if(!$status){
    undef $/;
    eval <RP>;
    if($@){
      $/ = "\n";
      die "\ncant recreate data dump.\n$@\n";
    }
    close(RP);
    $/ = "\n";
  }
  else{
    warn "\ncan't open data dumping file! Already cleaned?\n";
    $status = 0;
  }

  if(!$option){
    #remove files (fasta, chunks, sql)
    if(-e $dataDIR."/".$vertrna){
      $cmd = "rm " . $dataDIR."/".$vertrna;
      $status += system($cmd);
    }
    if(-e $dataDIR."/".$vertrna_update){
      $cmd = "rm " . $dataDIR."/".$vertrna_update;
      $status += system($cmd);
    }
    if(-e $dataDIR."/".$refseq){
      $cmd = "rm " . $dataDIR."/".$refseq;
      $status += system($cmd);
    }
    print "\n\nshould we remove the clipped fasta files? (y/n)   ";
    chomp($ans = <STDIN>);
    if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
      if(-e $dataDIR."/".$newfile){
		$cmd = "rm " . $dataDIR."/".$newfile;
		$status += system($cmd);
      }
	  if(-e $dataDIR."/$newfile".".seqs"){
    	$cmd = "rm " . $dataDIR."/$newfile".".seqs";
    	$status += system($cmd);
      }
	  if(-e $dataDIR."/$newfile".".seqs.clipped"){
    	$cmd = "rm " . $dataDIR."/$newfile".".seqs.clipped";
    	$status += system($cmd);
      }
	  
    }
    if(-e $dataDIR."/import_tables.sql"){
      $cmd = "rm " . $dataDIR."/import_tables.sql";
      $status += system($cmd);
    }
    if(-e $dataDIR."/import_tables2.sql"){
      $cmd = "rm " . $dataDIR."/import_tables2.sql";
      $status += system($cmd);
    }
    if(-e $dataDIR."/import_tables3.sql"){
      $cmd = "rm " . $dataDIR."/import_tables3.sql";
      $status += system($cmd);
    }
    #clean output directories
    if(!checkdir($chunkDIR, 0)){ warn "could not prepare directory! [".$chunkDIR."]";}
	if(!checkdir($chunkDIR."2", 0)){ warn "could not prepare directory! [".$chunkDIR."2]";}
	if(!checkdir($chunkDIR."3", 0)){ warn "could not prepare directory! [".$chunkDIR."3]";}
    
	if(!checkdir($outDIR, 0))  { warn "could not prepare directory! [".$outDIR."]";}
	if(!checkdir($outDIR."2", 0))  { warn "could not prepare directory! [".$outDIR."2]";}
	if(!checkdir($outDIR."3", 0))  { warn "could not prepare directory! [".$outDIR."3]";}

	#remove the other temporary output files:
	
	if(-e $dataDIR."/missing_cdnas.fasta"){
      $cmd = "rm " . $dataDIR."/missing_cdnas.fasta";
      $status += system($cmd);
    }
	if(-e $dataDIR."/single_file.out"){
      $cmd = "rm " . $dataDIR."/single_file.out";
      $status += system($cmd);
    }
	if(-e $dataDIR."/failed_hits.out"){
      $cmd = "rm " . $dataDIR."/failed_hits.out";
      $status += system($cmd);
    }

	if($status){ warn("Error deleting files.\n"); $status = 0; }

    #remove dbs
    print "\n\nshould we remove the pipeline database? (y/n)   ";
    chomp($ans = <STDIN>);
    if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
      $status += system("mysql -h$WB_PIPE_DBHOST -P$WB_PIPE_DBPORT -u$WB_DBUSER -p$WB_DBPASS -e\"drop database IF EXISTS $WB_PIPE_DBNAME;\"");
    }
    if($status){ warn("Error deleting databases.\n"); $status = 0; }

    print "cleaned out databases, removed temporary files.\n";
  }

  if(%saved_files){
    #restore original config files
    foreach my $config_file (keys %saved_files){
      if($saved_files{$config_file}){
		$cmd = "mv ".$dataDIR."/configbackup/".$config_file." ".$cvsDIR."/".$saved_files{$config_file};
      }
      else{
		$cmd = "rm ".$configDIR."/".$config_file;
      }
      $status += system($cmd);
    }
  }
  if($status){ warn("Error restoring config files.\n") }
  print "restored original config files.\n\n";
  if((-e "config_paths.perldata") and (system("rm config_paths.perldata"))){
    warn "\ncould not remove perldata file.\n";
  }
}


#partly clean-up after error

sub unclean_exit{
  clean_up(1);
  print "\n Restored original config files.\n Check for errors and restart script.\n";
  exit 1;
}


#compare results to previous data as a health-check
#can also bsub a further function call for every chromosome

sub compare{
  my (%chromosomes_1, %chromosomes_2);
  my ($sql, $sql2, $sth1, $sth2);
  my (%hits_per_chrom_1, %hits_per_chrom_2);
  my $hitcount1 = 0;
  my $hitcount2 = 0;
  my $ans = "";

  #should we exclude all the NT_x-regions?
  my $exclude_NT = 1;

  #get db connectors
  #old alignments
  my $db1 = db_connector($WB_LAST_DBHOST, $WB_LAST_DBPORT, $WB_LAST_DBNAME, "ensro");
  #new alignments
  my $db2 = db_connector($WB_TARGET_DBHOST, $WB_TARGET_DBPORT, $WB_TARGET_DBNAME, "ensro");

  #get chromosome names / ids
  $sql  = 'select coord_system_id from coord_system where name="chromosome"';
  $sth1 = $db1->prepare($sql) or die "sql error!";
  $sth1->execute();
  my ($coord_system_id1) = $sth1->fetchrow_array;
  $sth2 = $db2->prepare($sql) or die "sql error!";
  $sth2->execute();
  my ($coord_system_id2) = $sth2->fetchrow_array;
  
  $sql  = 'select seq_region_id, name from seq_region where coord_system_id = '.$coord_system_id1;
  if ($exclude_NT) {
    $sql .= ' and name not like "%NT%"';
  }
  $sth1 = $db1->prepare($sql) or die "sql error!";
  $sth1->execute();
  while (my ($seq_region_id, $name) = $sth1->fetchrow_array) {
    $chromosomes_1{$name} = $seq_region_id;
  }
  
  $sql  = 'select seq_region_id, name from seq_region where coord_system_id = '.$coord_system_id2;
  if ($exclude_NT) {
    $sql .= ' and name not like "%NT%"';
  }
  $sth2 = $db2->prepare($sql) or die "sql error!";
  $sth2->execute();
  while (my ($seq_region_id, $name) = $sth2->fetchrow_array) {
    $chromosomes_2{$name} = $seq_region_id;
  }


  print "Do you want to start the detailed analysis? (y/n) ";
  chomp($ans = <STDIN>);
  if($ans eq "y" or $ans eq "Y" or $ans eq "yes"){
    #create LSF jobs for in-depth analysis
    print "\nSubmitting jobs for detailed analysis.\n\n";
    foreach my $chromosome (keys %chromosomes_1){
      
      $cmd = "bsub -q normal -o ".$dataDIR."/".$chromosome.".out perl ".$cvsDIR.
             "/ensembl-pipeline/scripts/cDNA_update/comparison.pl ".
             " -chrom ".$chromosome." -oldname ".$oldFeatureName." -newname ".$newFeatureName." -dir ".$dataDIR.
             " -olddbhost ".$WB_LAST_DBHOST." -olddbport ".$WB_LAST_DBPORT." -olddbname ".$WB_LAST_DBNAME.
             " -newdbhost ".$WB_TARGET_DBHOST." -newdbport ".$WB_TARGET_DBPORT." -newdbname ".$WB_TARGET_DBNAME.
             " -olddnadbhost ".$WB_LAST_DNADBHOST." -olddnadbport ".$WB_LAST_DNADBPORT." -olddnadbname ".$WB_LAST_DNADBNAME.
	     " -newdnadbhost ".$WB_PIPE_DBHOST." -newdnadbport ".$WB_PIPE_DBPORT." -newdnadbname ".$WB_PIPE_DBNAME;
      #print $cmd."\n";
      if(system($cmd)){ warn " some error occurred when submitting job!\n$cmd\n "; }
    }
  }

  print "\nGetting hits per chromosome\n".
        "\told\tnew\n";
  #check hits per chromosome
  $sql = "select count(*) from  dna_align_feature daf, analysis a where a.logic_name='".
         $oldFeatureName."' and a.analysis_id=daf.analysis_id and daf.seq_region_id=?";
  $sth1 = $db1->prepare($sql) or die "sql error!";
  $sql = "select count(*) from  dna_align_feature daf, analysis a where a.logic_name='".
         $newFeatureName."' and a.analysis_id=daf.analysis_id and daf.seq_region_id=?";

  $sth2 = $db2->prepare($sql) or die "sql error!";

  my @sorted_chromosomes = sort bychrnum keys %chromosomes_1;
  foreach my $chromosome (@sorted_chromosomes) {
    $sth1->execute($chromosomes_1{$chromosome});
    $sth2->execute($chromosomes_2{$chromosome});
    $hits_per_chrom_1{$chromosome} = $sth1->fetchrow_array;
    $hits_per_chrom_2{$chromosome} = $sth2->fetchrow_array;
    print "\n$chromosome:".
      "\t".$hits_per_chrom_1{$chromosome}.
      "\t".$hits_per_chrom_2{$chromosome};
    $hitcount1 += $hits_per_chrom_1{$chromosome};
    $hitcount2 += $hits_per_chrom_2{$chromosome};
  }

  print "\n\nsum:".
      "\t".$hitcount1.
      "\t".$hitcount2."\n\n";
}


#sort chroms by name

sub bychrnum {
  my @awords = split /_/,$a;
  my @bwords = split /_/,$b;

  my $anum = $awords[0];
  my $bnum = $bwords[0];

  $anum =~ s/chr//;
  $bnum =~ s/chr//;

  if ($anum !~ /^[0-9]*$/) {
    if ($bnum !~ /^[0-9]*$/) {
      return $anum cmp $bnum;
    } else {
      return 1;
    }
  }
  if ($bnum !~ /^[0-9]*$/) {
    return -1;
  }

  if ($anum <=> $bnum) {
    return $anum <=> $bnum;
  } else {
    if ($#awords == 0) {
      return -1;
    } elsif ($#bwords == 0) {
      return 1;
    } else {
      return $awords[1] cmp $bwords[1];
    }
  }
}


#get a db connection

sub db_connector{
  my $host       = shift;
  my $port       = shift;
  my $dbname     = shift;
  my $user       = shift;
  my $dbCon      = new Bio::EnsEMBL::DBSQL::DBConnection(
							-host    => $host,
							-port    => $port,
							-user    => $user,
							-dbname  => $dbname
						       );
  if(!$dbCon){ die "\ncould not connect to \"$dbname\".\n"; }
  return $dbCon;
}


#connect to a given database, optional with attached DNA db

sub connect_db{
  my $host       = shift;
  my $port       = shift;
  my $dbname     = shift;
  my $user       = shift;
  my $pass       = shift;
  my $dnadb      = shift;
  my $dbObj;

  if($dnadb){
    $dbObj      = new Bio::EnsEMBL::DBSQL::DBAdaptor(
						     -host   => $host,
						     -port   => $port,
						     -user   => $user,
						     -pass   => $pass,
						     -dbname => $dbname,
						     -dnadb  => $dnadb
						    );
  }
  else{
    $dbObj      = new Bio::EnsEMBL::DBSQL::DBAdaptor(
						     -host    => $host,
						     -port    => $port,
						     -user    => $user,
						     -pass    => $pass,
						     -dbname  => $dbname
						    );
  }
  if(!$dbObj){
    return 0;
  }
  return $dbObj;
}


1;


__END__


The following errors are reported, but can be ignored:

"OSTYPE: Undefined variable"

"You should also add a rule that has SubmitcDNAChunk as its goal,
or this rule will never have its conditions fulfilled."


"-------------------- WARNING ----------------------
MSG: Some of your analyses don t have entries in the input_id_type_analysis table
FILE: Pipeline/Utils/PipelineSanityChecks.pm LINE: 99
CALLED BY: Pipeline/Utils/PipelineSanityChecks.pm  LINE: 73
---------------------------------------------------"

"MSG: Could not find fasta file for 'MT in '/data/blastdb/Ensembl/Human/NCBI35/softmasked_dusted'"

_________________________________________________________

