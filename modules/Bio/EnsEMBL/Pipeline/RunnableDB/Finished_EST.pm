
### Bio::EnsEMBL::Pipeline::RunnableDB::Finished_EST

package Bio::EnsEMBL::Pipeline::RunnableDB::Finished_EST;

use strict;

use Bio::EnsEMBL::Pipeline::RunnableDB;
use Bio::Root::RootI;
use Bio::EnsEMBL::Pipeline::SeqFetcher::Pfetch;
use Bio::EnsEMBL::Pipeline::SeqFetcher::Getseqs;
use Bio::EnsEMBL::Pipeline::Runnable::Finished_EST;
use Bio::EnsEMBL::Pipeline::SeqFetcher::OBDAIndexSeqFetcher;

use vars qw(@ISA);
@ISA = qw(Bio::EnsEMBL::Pipeline::RunnableDB);

sub new {
    my ( $new, @args ) = @_;
    my $self = $new->SUPER::new(@args);

    # dbobj, input_id, seqfetcher, and analysis objects are all set in
    # in superclass constructor (RunnableDB.pm)
#print STDERR Dumper($self);
    return $self;
}

sub fetch_input {
    my ($self) = @_;

    my @fps;

    $self->throw("No input id") unless defined( $self->input_id );

    my $contigid = $self->input_id;
#    my $contig   = $self->dbobj->get_Contig($contigid); #changed to
    my $rawContigAdaptor = $self->db->get_RawContigAdaptor();
    my $contig   = $rawContigAdaptor->fetch_by_name($contigid);
    
#    my $genseq   = $contig->primary_seq; # changed to
    my $genseq   = $contig;
    my $masked   = $contig->get_repeatmasked_seq;

    my $seq = $masked->seq;
    if ( $seq =~ /[CATG]{3}/ ) {
        $self->input_is_void(0);
    }
    else {
        $self->input_is_void(1);
        $self->warn("Need at least 3 nucleotides");
    }

    # Make seqfetcher
    my $seqfetcher = $self->make_seqfetcher;
    $self->seqfetcher($seqfetcher);



    my $runnable = Bio::EnsEMBL::Pipeline::Runnable::Finished_EST->new(
        '-query'      => $masked,
        '-unmasked'   => $genseq,
        '-seqfetcher' => $seqfetcher,
        '-analysis'   => $self->analysis,
    );

    $self->runnable($runnable);
}

sub runnable {
    my ( $self, $arg ) = @_;

    if ( defined($arg) ) {
        $self->throw("[$arg] is not a Bio::EnsEMBL::Pipeline::RunnableI")
          unless $arg->isa("Bio::EnsEMBL::Pipeline::RunnableI");

        $self->{_runnable} = $arg;
    }

    return $self->{_runnable};
}

sub run {
    my ($self) = @_;

    my $runnable = $self->runnable;
    $runnable || $self->throw("Can't run - no runnable object");

    $runnable->run;

#    die (Dumper ($runnable));

#     if ( my @output = $runnable->output ) { #
#      ## my $dbobj      = $self->dbobj; # changed to
#         my $dbobj      = $self->db; #
#         my $seqfetcher = $self->make_seqfetcher; #
#         my %ids        = map { $_->hseqname, $_ } @output; #

#        $seqfetcher->write_descriptions( $dbobj, keys(%ids) ); #
#     } #

}
#sub write_output{
#    my($self) = @_;
#    if ( my @output = $self->runnable->output ) {
##        my $dbobj      = $self->dbobj; # changed to
#        my $dbobj      = $self->db;
#        my $seqfetcher = $self->make_seqfetcher;
#        my %ids        = map { $_->hseqname, $_ } @output;
#	die(Dumper(%ids));
#        $seqfetcher->write_descriptions( $dbobj, keys(%ids) );
#    }
#}



sub output {
    my ($self) = @_;

    my @runnable = $self->runnable;
    my @results;
    foreach my $runnable (@runnable) {
        print STDERR "runnable = " . $runnable[0] . "\n";
        push ( @results, $runnable->output );
    }
   
   
    return @results;
}

sub make_seqfetcher {
    my ( $self, $index ) = @_;

    my $seqfetcher;
    if ( my $dbf = $self->analysis->db_file ) { #

        my @dbs = $dbf; #
        $seqfetcher = #
          Bio::EnsEMBL::Pipeline::SeqFetcher::OBDAIndexSeqFetcher->new( #
            -db => \@dbs, #
        ); #

    } #
    else { #
        $seqfetcher = Bio::EnsEMBL::Pipeline::SeqFetcher::Pfetch->new;
    } #
    return $seqfetcher;
}





1;

__END__

=head1 NAME - Bio::EnsEMBL::Pipeline::RunnableDB::Finished_EST

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk
