#!/usr/local/ensembl/bin/perl -w


=head1 NAME

map_ExpressionData.pl

=head1 SYNOPSIS
 
this is a clone of run_EST_RunnableDB

=head1 DESCRIPTION


=head1 OPTIONS

    -host      host name for database (gets put as host= in locator)

    -port      For RDBs, what port to connect to (port= in locator)

    -dbname    For RDBs, what name to connect to (dbname= in locator)

    -dbuser    For RDBs, what username to connect as (dbuser= in locator)

    -dbpass    For RDBs, what password to use (dbpass= in locator)

    -input_id  The input id for the RunnableDB

    -runnable  The name of the runnable module we want to run

    -analysis  The number of the analysisprocess we want to run
=cut

use strict;
use Getopt::Long;

# this script connects to the db it is going to write to

use Bio::EnsEMBL::Pipeline::RunnableDB::MapGeneToExpression;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Pipeline::ESTConf qw ( EST_E2G_DBNAME
                                         EST_E2G_DBHOST
	                                 EST_E2G_DBUSER
	                                 EST_E2G_DBPASS
                                       );


use Bio::EnsEMBL::DBSQL::DBAdaptor;
#use Bio::EnsEMBL::DBLoader;

my $dbtype = 'rdb';
my $port   = undef;
my $dbname = $EST_E2G_DBNAME;
my $dbuser = $EST_E2G_DBUSER;
my $dbpass = $EST_E2G_DBPASS;
my $host   = $EST_E2G_DBHOST;


my $runnable;
my $input_id;
my $write  = 0;
my $check  = 0;
my $params;
my $pepfile;
my $acc;

# can override db options on command line
&GetOptions( 
	     'input_id:s'    => \$input_id,
	     'runnable:s'    => \$runnable,
	     'write'         => \$write,
             'check'         => \$check,
             'parameters:s'  => \$params,
             'dbname:s'      => \$dbname,
             'dbhost:s'      => \$host,
             'dbuser:s'      => \$dbuser,
             'dbpass:s'      => \$dbpass,
	     );

$| = 1;

die "No runnable entered" unless defined ($runnable);
(my $file = $runnable) =~ s/::/\//g;
require "$file.pm";

if ($check) {
   exit(0);
}

#print STDERR "args: $host : $dbuser : $dbpass : $dbname\n";

my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(
    -host             => $host,
    -user             => $dbuser,
    -dbname           => $dbname,
    -pass             => $dbpass,
    -perlonlyfeatures => 0,
);

die "No input id entered" unless defined ($input_id);

my %hparams;
# eg -parameters param1=value1,param2=value2
if (defined $params){
  foreach my $p(split /,/, $params){
    my @sp = split /=/, $p;
    $sp[0] = '-' . $sp[0];
    $hparams{$sp[0]} =  $sp[1];
  }
}


my $runobj = "$runnable"->new(-dbobj    => $db,
			      -input_id => $input_id,
			      %hparams,
			     );


$runobj->fetch_input;
$runobj->run;

my %expression_map = %{ $runobj->output };


if ($write) {
  $runobj->write_output;
}

