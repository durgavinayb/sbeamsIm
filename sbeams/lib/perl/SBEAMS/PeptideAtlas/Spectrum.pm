package SBEAMS::PeptideAtlas::Spectrum;

###############################################################################
# Class       : SBEAMS::PeptideAtlas::Spectrum
# Author      : Eric Deutsch <edeutsch@systemsbiology.org>
#
=head1 SBEAMS::PeptideAtlas::Spectrum

=head2 SYNOPSIS

  SBEAMS::PeptideAtlas::Spectrum

=head2 DESCRIPTION

This is part of the SBEAMS::PeptideAtlas module which handles
things related to PeptideAtlas spectra

=cut
#
###############################################################################

use strict;
use Devel::Size  qw(size total_size);
use DB_File ;
use Data::Dumper;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError) ;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
require Exporter;
@ISA = qw();
$VERSION = q[$Id$];
@EXPORT_OK = qw();

use SBEAMS::Connection qw( $log );
use SBEAMS::Connection::Tables;
use SBEAMS::Connection::Settings;
use SBEAMS::PeptideAtlas::Tables;
use SBEAMS::Proteomics::Tables;

###############################################################################
# Global variables
###############################################################################
use vars qw($VERBOSE $TESTONLY $sbeams);
use Time::HiRes qw( usleep ualarm gettimeofday tv_interval);

our $fhs;
our $pk_counter;

###############################################################################
# Constructor
###############################################################################
sub new {
    my $this = shift;
    $fhs = shift;
    $pk_counter = shift;
    my $class = ref($this) || $this;
    my $self = {};
    bless $self, $class;
    $VERBOSE = 0;
    $TESTONLY = 0;
    return($self);
} # end new


###############################################################################
# setSBEAMS: Receive the main SBEAMS object
###############################################################################
sub setSBEAMS {
    my $self = shift;
    $sbeams = shift;
    return($sbeams);
} # end setSBEAMS



###############################################################################
# getSBEAMS: Provide the main SBEAMS object
###############################################################################
sub getSBEAMS {
    my $self = shift;
    return $sbeams || SBEAMS::Connection->new();
} # end getSBEAMS



###############################################################################
# setTESTONLY: Set the current test mode
###############################################################################
sub setTESTONLY {
    my $self = shift;
    $TESTONLY = shift;
    return($TESTONLY);
} # end setTESTONLY



###############################################################################
# setVERBOSE: Set the verbosity level
###############################################################################
sub setVERBOSE {
    my $self = shift;
    $VERBOSE = shift;
    return($TESTONLY);
} # end setVERBOSE



###############################################################################
# loadBuildSpectra -- Loads all spectra for specified build
###############################################################################
sub loadBuildSpectra {
  my $METHOD = 'loadBuildSpectra';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");

  my $atlas_build_directory = $args{atlas_build_directory}
    or die("ERROR[$METHOD]: Parameter atlas_build_directory not passed");

  my $organism_abbrev = $args{organism_abbrev}
    or die("ERROR[$METHOD]: Parameter organism_abbrev not passed");


  #### We now support two different file types
  #### First try to find the PAidentlist file
  my $filetype = 'PAidentlist';
  my $expected_n_columns = 21;
  my $peplist_file = "$atlas_build_directory/".
    "PeptideAtlasInput_concat.PAidentlist";

  #### Else try the older peplist file
  unless (-e $peplist_file) {
    print "WARNING: Unable to find PAidentlist file '$peplist_file'\n";

    $peplist_file = "$atlas_build_directory/".
      "APD_${organism_abbrev}_all.peplist";
    unless (-e $peplist_file) {
      print "ERROR: Unable to find peplist file '$peplist_file'\n";
      return;
    }
    #### Found it, so proceed but admonish user
    print "WARNING: Found older peplist file '$peplist_file'\n";
    print "         This file type is deprecated, but will load anyway\n";
    $filetype = 'peplist';
    $expected_n_columns = 17;
  }


  #### Find and open the input peplist file
  unless (open(INFILE,$peplist_file)) {
    print "ERROR: Unable to open for read file '$peplist_file'\n";
    return;
  }


  #### Read and verify header if a peplist file
  if ($filetype eq 'peplist') {
    my $header = <INFILE>;
    unless ($header && substr($header,0,10) eq 'search_bat' &&
	    length($header) == 155) {
      print "len = ".length($header)."\n";
      print "ERROR: Unrecognized header in peplist file '$peplist_file'\n";
      close(INFILE);
      return;
    }
  }
  
  my $exp_list_file = "$atlas_build_directory/../Experiments.list"; 
  my $sql = qq~
    SELECT FRAGMENTATION_TYPE, FRAGMENTATION_TYPE_ID
    FROM $TBAT_FRAGMENTATION_TYPE
  ~;
  my %fragmentation_name2id = $sbeams->selectTwoColumnHash($sql);
  my %exp_loc = ();
  open (EXP, "<$exp_list_file" ) or die "cannot open $exp_list_file\n";
  while (my $line =<EXP>){
    chomp $line;
    next if ($line =~ /^#/ || $line =~ /^$/);
    my ($id, $loc) = split(/\s+/, $line);
    $exp_loc{$id} = $loc;
  }
  close EXP;

  #### Loop through all spectrum identifications and load
  my $spectrum_identification_fh;
  open ($spectrum_identification_fh, ">spectrum_identifications.txt") 
     if (! $fhs->{spectrum_identification});
  my @columns;
  my $pre_search_batch_id;
  my $spec_counter =0;
  my %fragmentation_type_ids =();

  while ( my $line = <INFILE>) {
    $spec_counter++;
    chomp $line;
    #if ($spec_counter <200000000 ){
    #  next;
    #}
    @columns = split("\t",$line,-1);
    unless (scalar(@columns) == $expected_n_columns || scalar(@columns) == $expected_n_columns-2) {
      #18 retention_time_sec
     # 19 20 ptms
				die("ERROR: Unexpected number of columns (".
				scalar(@columns)."!=$expected_n_columns) in\n$line");
    }

    my ($search_batch_id,$spectrum_name,$peptide_accession,$peptide_sequence,
        $preceding_residue,$modified_sequence,$following_residue,$charge,
        $probability,$massdiff,$protein_name,$proteinProphet_probability,
        $n_proteinProphet_observations,$n_sibling_peptides,
        $SpectraST_probability, $ptm_sequence,$precursor_intensity,$ptm_lability,
        $total_ion_current,$signal_to_noise,$retention_time_sec,$chimera_level);
    if ($filetype eq 'peplist') {
      ($search_batch_id,$peptide_sequence,$modified_sequence,$charge,
        $probability,$protein_name,$spectrum_name) = @columns;
    } elsif ($filetype eq 'PAidentlist') {
      ($search_batch_id,
				$spectrum_name,
				$peptide_accession,
				$peptide_sequence,
				$preceding_residue,
				$modified_sequence,
				$following_residue,
				$charge,
				$probability,
				$massdiff,
				$protein_name,
				$proteinProphet_probability,
				$n_proteinProphet_observations,
				$n_sibling_peptides,
				$precursor_intensity,
				$total_ion_current,
				$signal_to_noise,
        $retention_time_sec,
				$chimera_level,
        $ptm_sequence,
        $ptm_lability) = @columns;
      #### Correction for occasional value '+-0.000000'
      $massdiff =~ s/\+\-//;
    } else {
      die("ERROR: Unexpected filetype '$filetype'");
    }

    if($pre_search_batch_id ne $search_batch_id){

      print "\nsearch_batch_id: $pre_search_batch_id, $spec_counter records processed\n";
      %fragmentation_type_ids = ();

      ## read fragmentation_types.tsv files
      my $dir = "$exp_loc{$search_batch_id}/../data/";
      if (-d "$dir"){
        opendir ( DIR, $dir) || die "Error in opening dir $dir\n";
        while( (my $filename = readdir(DIR))) {
           next if($filename !~ /^(.*)\.fragmentation_types.tsv/);
           my $run_name = $1;
           open (FRAG, "<$dir/$filename");
           while (my $line =<FRAG>){
              chomp $line;
              my ($scan, $name) = split(/\t/, $line);
              next if(not defined $fragmentation_name2id{$name});
              $fragmentation_type_ids{$run_name}{$scan} = $fragmentation_name2id{$name};
           }
        }
        close FRAG;
        closedir(DIR);
      }
      if (! %fragmentation_type_ids){
         print "WARNING: no fragmentation_type_id file in $dir\n";
      }
    }

    if ($peptide_sequence !~ /[JUO]/){

			$self->insertSpectrumIdentification(
				 atlas_build_id => $atlas_build_id,
				 search_batch_id => $search_batch_id,
				 modified_sequence => $modified_sequence,
				 ptm_sequence => $ptm_sequence,
				 ptm_lability => $ptm_lability,
				 charge => $charge,
				 probability => $probability,
				 protein_name => $protein_name,
				 spectrum_name => $spectrum_name,
				 massdiff => $massdiff,
				 precursor_intensity => $precursor_intensity,
				 total_ion_current => $total_ion_current,
				 signal_to_noise => $signal_to_noise,
				 retention_time_sec => $retention_time_sec,
				 chimera_level => $chimera_level, 
				 spectrum_identification_fh => $spectrum_identification_fh,
         fragmentation_type_ids => \%fragmentation_type_ids
			);
    }
    $pre_search_batch_id = $search_batch_id;
    #print "$spec_counter... " if ($spec_counter %10000 == 0);
  }
  close $spectrum_identification_fh if (! $fhs->{spectrum_identification});

  return if ($fhs->{spectrum_identification});

	my $commit_interval = 1000;
  open (IN, "<spectrum_identifications.txt"); 
	print  localtime() .": insert spectrum_identifications\n";
	my $cnt=0;
	$sbeams->initiate_transaction(); 
	while (my $line =<IN>){
    chomp $line;
		my ($spectrum_id, $modified_peptide_instance_id,$atlas_search_batch_id, $probability, $massdiff) = split(",", $line);
		my $spectrum_identification_id = $self->insertSpectrumIdentificationRecord(
			modified_peptide_instance_id => $modified_peptide_instance_id,
			spectrum_id => $spectrum_id,
			atlas_search_batch_id => $atlas_search_batch_id,
			probability => $probability,
			massdiff => $massdiff,
		 );
		 $cnt++;
		 unless ($cnt % $commit_interval){
				$sbeams->commit_transaction();
				print "$cnt... ";
		 }
	}
  $sbeams->commit_transaction();
  $sbeams->reset_dbh();
	print localtime() ."\n";
} # end loadBuildSpectra

###############################################################################
# loadBuildPTMSpectra -- Loads all spectra for specified build
###############################################################################
sub loadBuildPTMSpectra {
  my $METHOD = 'loadBuildPTMSpectra';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");

  my $atlas_build_directory = $args{atlas_build_directory}
    or die("ERROR[$METHOD]: Parameter atlas_build_directory not passed");

  my $organism_abbrev = $args{organism_abbrev}
    or die("ERROR[$METHOD]: Parameter organism_abbrev not passed");


  #### We now support two different file types
  #### First try to find the PAidentlist file
  my $filetype = 'PAidentlist';
  my $expected_n_columns = 20;
  my $peplist_file = "$atlas_build_directory/".
    "PeptideAtlasInput_concat.PAidentlist";

  #### Else try the older peplist file
  unless (-e $peplist_file) {
    print "WARNING: Unable to find PAidentlist file '$peplist_file'\n";
  }

  #### Find and open the input peplist file
  unless (open(INFILE,$peplist_file)) {
    print "ERROR: Unable to open for read file '$peplist_file'\n";
    return;
  }


  #### Read and verify header if a peplist file
  if ($filetype eq 'peplist') {
    my $header = <INFILE>;
    unless ($header && substr($header,0,10) eq 'search_bat' &&
	    length($header) == 155) {
      print "len = ".length($header)."\n";
      print "ERROR: Unrecognized header in peplist file '$peplist_file'\n";
      close(INFILE);
      return;
    }
  }

  #### Loop through all spectrum identifications and load
  my $ptm_spectrum_identifications; 
  open ($ptm_spectrum_identifications, ">ptm_spectrum_identifications.txt");
  my @columns;
  my $pre_search_batch_id;
  my $spec_counter =0;
  while ( my $line = <INFILE>) {
    $spec_counter++;
    chomp $line;
    #if ($spec_counter <200000000 ){
    #  next;
    #}
    @columns = split("\t",$line,-1);
    unless (scalar(@columns) == 21 || scalar(@columns) == 20 ){
      die("ERROR: Unexpected number of columns (scalar(@columns)) !=$expected_n_columns) in\n$line\n");
    }

    my ($search_batch_id,$spectrum_name,$peptide_accession,$peptide_sequence,
        $preceding_residue,$modified_sequence,$following_residue,$charge,
        $probability,$massdiff,$protein_name,$proteinProphet_probability,
        $n_proteinProphet_observations,$n_sibling_peptides,
        $SpectraST_probability, $ptm_sequence,$precursor_intensity,
        $total_ion_current,$signal_to_noise,$retention_time_sec,$chimera_level,$ptm_lability);
    if ($filetype eq 'peplist') {
      ($search_batch_id,$peptide_sequence,$modified_sequence,$charge,
        $probability,$protein_name,$spectrum_name) = @columns;
    } elsif ($filetype eq 'PAidentlist') {
      ($search_batch_id,
				$spectrum_name,
				$peptide_accession,
				$peptide_sequence,
				$preceding_residue,
				$modified_sequence,
				$following_residue,
				$charge,
				$probability,
				$massdiff,
				$protein_name,
				$proteinProphet_probability,
				$n_proteinProphet_observations,
				$n_sibling_peptides,
				$precursor_intensity,
				$total_ion_current,
				$signal_to_noise,
        $retention_time_sec,
				$chimera_level,
        $ptm_sequence,
        $ptm_lability) = @columns;
      #### Correction for occasional value '+-0.000000'
      $massdiff =~ s/\+\-//;
    } else {
      die("ERROR: Unexpected filetype '$filetype'");
    }
    
		next if ($modified_sequence =~ /[JUO]/);
    if ($ptm_sequence){
			#### Get the sample_id for this search_batch_id
			my $sample_id = $self->get_sample_id(
				proteomics_search_batch_id => $search_batch_id,
			);

			#### Get the atlas_search_batch_id for this search_batch_id
			my $atlas_search_batch_id = $self->get_atlas_search_batch_id(
				proteomics_search_batch_id => $search_batch_id,
			);

			#### get spectrum id  
			my $spectrum_id = $self->get_spectrum_id(
				sample_id => $sample_id,
				spectrum_name => $spectrum_name,
			 atlas_build_id => $atlas_build_id
			);
		  if ( ! $spectrum_id){	
        print "WARNING: no spectrum_id for name=$spectrum_name\n";
        next;
      }
			my $spectrum_identification_id = $self->get_spectrum_identification_id(
				spectrum_id => $spectrum_id,
				atlas_search_batch_id => $atlas_search_batch_id,
				atlas_build_id => $atlas_build_id,
			);

      if ($spectrum_identification_id){
				my $ptm_spectrum_identification_id = $self->get_ptm_spectrum_identification_id(
					spectrum_identification_id => $spectrum_identification_id,
          atlas_search_batch_id => $atlas_search_batch_id,
          atlas_build_id => $atlas_build_id,
 
				);
        if (! $ptm_spectrum_identification_id){
				  print $ptm_spectrum_identifications "$spectrum_identification_id;$ptm_sequence;$ptm_lability\n";
        }
      }else{
        print "WARNNING: no spectrum_identification_id for spectrum_id=$spectrum_id, name=$spectrum_name\n";
      }
    }

    if($pre_search_batch_id ne $search_batch_id){
      print "\nsearch_batch_id: $pre_search_batch_id, $spec_counter records processed\n";
    }
    $pre_search_batch_id = $search_batch_id;
    print "$spec_counter... " if ($spec_counter %10000 == 0);
  }
  close $ptm_spectrum_identifications;
	my $commit_interval = 1000;
  open (IN, "<ptm_spectrum_identifications.txt"); 
	print  localtime() .": insert ptm_spectrum_identifications\n";
	my $cnt=0;
	$sbeams->initiate_transaction(); 
	while (my $line =<IN>){
    chomp $line;
		my ($spectrum_identification_id, $ptm_sequence,$ptm_lability) = split(";", $line);
		my $spectrum_identification_id = $self->insertSpectrumPTMIdentificationRecord(
		  spectrum_identification_id => $spectrum_identification_id,	
			ptm_sequence => $ptm_sequence,
      ptm_lability => $ptm_lability
		 );
		 $cnt++;
		 unless ($cnt % $commit_interval){
				$sbeams->commit_transaction();
				print "$cnt... ";
		 }
	}
  $sbeams->commit_transaction();
  $sbeams->reset_dbh();
  print localtime() ."\n";

} # end loadBuildPTMSpectra

###############################################################################
# insertPTMSpectrumIdentification --
###############################################################################
sub insertPTMSpectrumIdentification {
  my $METHOD = 'insertPTMSpectrumIdentification';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");
  my $search_batch_id = $args{search_batch_id}
    or die("ERROR[$METHOD]: Parameter search_batch_id not passed");
  my $modified_sequence = $args{modified_sequence}
    or die("ERROR[$METHOD]: Parameter modified_sequence not passed");
  my $ptm_sequence = $args{ptm_sequence} || '';
  my $ptm_lability = $args{ptm_lability} || ''; 
  my $charge = $args{charge}
    or die("ERROR[$METHOD]: Parameter charge not passed");
  my $protein_name = $args{protein_name}
    or die("ERROR[$METHOD]: Parameter protein_name not passed");
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $ptm_spectrum_identifications = $args{ptm_spectrum_identifications};

  return if ($modified_sequence =~ /[JUO]/);
  #### Get the sample_id for this search_batch_id
  my $sample_id = $self->get_sample_id(
    proteomics_search_batch_id => $search_batch_id,
  );

  #### Get the atlas_search_batch_id for this search_batch_id
  my $atlas_search_batch_id = $self->get_atlas_search_batch_id(
    proteomics_search_batch_id => $search_batch_id,
  );

  #### Check to see if this spectrum is already in the database
  my $spectrum_id = $self->get_spectrum_id(
    sample_id => $sample_id,
    spectrum_name => $spectrum_name,
   atlas_build_id => $atlas_build_id
  );
  #### Check to see if this spectrum_identification is in the database
  my $spectrum_identification_id = $self->get_spectrum_identification_id(
    spectrum_id => $spectrum_id,
    atlas_search_batch_id => $atlas_search_batch_id,
    atlas_build_id => $atlas_build_id,
  );

  return $spectrum_identification_id; 

} # end insertPTMSpectrumIdentification

###############################################################################
# insertSpectrumIdentification --
###############################################################################
sub insertSpectrumIdentification {
  my $METHOD = 'insertSpectrumIdentification';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");
  my $search_batch_id = $args{search_batch_id}
    or die("ERROR[$METHOD]: Parameter search_batch_id not passed");
  my $modified_sequence = $args{modified_sequence}
    or die("ERROR[$METHOD]: Parameter modified_sequence not passed");
  my $ptm_sequence = $args{ptm_sequence} || ''; 
  my $ptm_lability = $args{ptm_lability} || '';

  my $charge = $args{charge}
    or die("ERROR[$METHOD]: Parameter charge not passed");
  my $protein_name = $args{protein_name}
    or die("ERROR[$METHOD]: Parameter protein_name not passed");
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $spectrum_identification_fh = $args{spectrum_identification_fh};

  my $fragmentation_type_ids = $args{fragmentation_type_ids}
    or die("ERROR[$METHOD]: Parameter  fragmentation_type_ids not passed");

  my $massdiff = $args{massdiff};
  my $chimera_level = $args{chimera_level}; 
  my $probability = $args{probability};
  die("ERROR[$METHOD]: Parameter probability not passed") if($probability eq '');
  my $precursor_intensity = $args{precursor_intensity};
  my $total_ion_current = $args{total_ion_current};
  my $signal_to_noise = $args{signal_to_noise};
  my $retention_time_sec = $args{retention_time_sec};
  our $counter;

  #### Get the modified_peptide_instance_id for this peptide
  my $modified_peptide_instance_id = $self->get_modified_peptide_instance_id(
    atlas_build_id => $atlas_build_id,
    modified_sequence => $modified_sequence,
    charge => $charge,
  );

  #### Get the sample_id for this search_batch_id
  my $sample_id = $self->get_sample_id(
    proteomics_search_batch_id => $search_batch_id,
  );

  #### Get the atlas_search_batch_id for this search_batch_id
  my $atlas_search_batch_id = $self->get_atlas_search_batch_id(
    proteomics_search_batch_id => $search_batch_id,
  );

  #### Check to see if this spectrum is already in the database
  my $spectrum_id = $self->get_spectrum_id(
    sample_id => $sample_id,
    spectrum_name => $spectrum_name,
   atlas_build_id => $atlas_build_id
  );

  #### If not, INSERT it
  unless ($spectrum_id) {
    if ($chimera_level eq ''){
      $chimera_level = 'NULL';
    }
    $spectrum_id = $self->insertSpectrumRecord(
      sample_id => $sample_id,
      spectrum_name => $spectrum_name,
      proteomics_search_batch_id => $search_batch_id,
      chimera_level => $chimera_level,
      precursor_intensity => $precursor_intensity,
      total_ion_current => $total_ion_current,
      signal_to_noise => $signal_to_noise,
      retention_time_sec => $retention_time_sec,
      fragmentation_type_ids=>$fragmentation_type_ids
    );
    $counter++;
    print "$counter..." if ($counter/1000 == int($counter/1000));
  }
  #### Check to see if this spectrum_identification is in the database
  my $spectrum_identification_id = $self->get_spectrum_identification_id(
    spectrum_id => $spectrum_id,
    atlas_search_batch_id => $atlas_search_batch_id,
    atlas_build_id => $atlas_build_id,
  );

  #### If not, save to array and insert later 
  unless ($spectrum_identification_id) {
    if ($fhs->{spectrum_identification}){
      my $fh = $fhs->{spectrum_identification};
      print $fh "$pk_counter->{spectrum_identification}\t$modified_peptide_instance_id\t$probability\t$spectrum_id\t$atlas_search_batch_id\t$massdiff\n";
			if ($ptm_sequence){
				$fh = $fhs->{spectrum_ptm_identification};
				my @ptm_sequences = split(",", $ptm_sequence);
				my @ptm_labilities = split(",",$ptm_lability);

				for (my $i=0; $i<=$#ptm_sequences;$i++){
					my $sequence = $ptm_sequences[$i];
					my $lability = $ptm_labilities[$i];
					$sequence =~ /\[(\S+)\](.*)/;
					print $fh "$pk_counter->{spectrum_ptm_identification}\t$pk_counter->{spectrum_identification}\t$2\t$1\t$lability\n";
					$pk_counter->{spectrum_ptm_identification}++;
				}
			}
      $pk_counter->{spectrum_identification}++;
    }else{
      print $spectrum_identification_fh  "$spectrum_id,$modified_peptide_instance_id,$atlas_search_batch_id,$probability,$massdiff\n";
    }
  }
} # end insertSpectrumIdentification



###############################################################################
# get_modified_peptide_instance_id --
###############################################################################
sub get_modified_peptide_instance_id {
  my $METHOD = 'get_modified_peptide_instance_id';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");
  my $modified_sequence = $args{modified_sequence}
    or die("ERROR[$METHOD]: Parameter modified_sequence not passed");
  my $charge = $args{charge}
    or die("ERROR[$METHOD]: Parameter charge not passed");

  #### If we haven't loaded all modified_peptide_instance_ids into the
  #### cache yet, do so
  our %modified_peptide_instance_ids;
  unless (%modified_peptide_instance_ids) {
    print "[INFO] Loading all modified_peptide_instance_ids...\n";
		my $cnt = 0;
    if ($fhs->{spectrum_identification}){
       ## read from file
       my $builds_directory = get_atlas_build_directory (atlas_build_id=> $atlas_build_id);
       my $modified_peptide_instance_file = "$builds_directory/../PeptideAtlas_build$atlas_build_id/modified_peptide_instance.txt";

       if (-e "$modified_peptide_instance_file"){
          open (M,"<$modified_peptide_instance_file") or die "cannot open $modified_peptide_instance_file\n";
          while(my $line =<M>){
             my @row = split("\t", $line);
             #modified_peptide_instance_id = $row[0];
             #modified_peptide_sequence = $row[2];
             #charge = $row[3];
             $modified_peptide_instance_ids{$row[3]}{$row[2]} = $row[0];
          } 
       }else{
         die "ERROR: $modified_peptide_instance_file not found\n"; 
       }
    }else{
			my $sql = qq~
				SELECT modified_peptide_instance_id,modified_peptide_sequence,
							 peptide_charge
					FROM $TBAT_MODIFIED_PEPTIDE_INSTANCE MPI
					JOIN $TBAT_PEPTIDE_INSTANCE PI
							 ON ( MPI.peptide_instance_id = PI.peptide_instance_id )
				 WHERE PI.atlas_build_id = $atlas_build_id
			~;

			my $sth = $sbeams->get_statement_handle( $sql );
			#### Loop through all rows and store in hash
			while ( my $row = $sth->fetchrow_arrayref() ) {
				$cnt++;
				my $modified_peptide_instance_id = $row->[0];
				#my $key = $row->[1].'/'.$row->[2];
				#$modified_peptide_instance_ids{$key} = $modified_peptide_instance_id;
				$modified_peptide_instance_ids{$row->[2]}{$row->[1]} = $modified_peptide_instance_id;
			}
    }
    print "       $cnt loaded...\n";
    print "       modified_peptide_instance_ids size: ". total_size(\%modified_peptide_instance_ids)/100000 ."MB\n";
  }


  #### Lookup and return modified_peptide_instance_id
  #my $key = "$modified_sequence/$charge";
  #if ($modified_peptide_instance_ids{$key}) {
  #  return($modified_peptide_instance_ids{$key});
  #};
  if ($modified_peptide_instance_ids{$charge}{$modified_sequence}) {
    return($modified_peptide_instance_ids{$charge}{$modified_sequence});
  };

  die("ERROR: Unable to find '$modified_sequence/$charge' in modified_peptide_instance_ids hash. ".
      "This should never happen.");

} # end get_modified_peptide_instance_id



###############################################################################
# get_sample_id --
###############################################################################
sub get_sample_id {
  my $METHOD = 'get_sample_id';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $proteomics_search_batch_id = $args{proteomics_search_batch_id}
    or die("ERROR[$METHOD]: Parameter proteomics_search_batch_id not passed");

  #### If we haven't loaded all sample_ids into the
  #### cache yet, do so
  our %sample_ids;
  unless (%sample_ids) {
    print "[INFO] Loading all sample_ids...\n";
    my $sql = qq~
      SELECT proteomics_search_batch_id,sample_id
        FROM $TBAT_ATLAS_SEARCH_BATCH
       WHERE record_status != 'D'
    ~;
    %sample_ids = $sbeams->selectTwoColumnHash($sql);

    print "       ".scalar(keys(%sample_ids))." loaded...\n";
  }


  #### Lookup and return sample_id
  if ($sample_ids{$proteomics_search_batch_id}) {
    return($sample_ids{$proteomics_search_batch_id});
  };

  die("ERROR: Unable to find '$proteomics_search_batch_id' in ".
      "sample_ids hash. This should never happen.");

} # end get_sample_id



###############################################################################
# get_atlas_search_batch_id --
###############################################################################
sub get_atlas_search_batch_id {
  my $METHOD = 'get_atlas_search_batch_id';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $proteomics_search_batch_id = $args{proteomics_search_batch_id}
    or die("ERROR[$METHOD]: Parameter proteomics_search_batch_id not passed");

  #### If we haven't loaded all atlas_search_batch_ids into the
  #### cache yet, do so
  our %atlas_search_batch_ids;
  unless (%atlas_search_batch_ids) {
    print "[INFO] Loading all atlas_search_batch_ids...\n";

    my $sql = qq~
      SELECT proteomics_search_batch_id,atlas_search_batch_id
        FROM $TBAT_ATLAS_SEARCH_BATCH
       WHERE record_status != 'D'
    ~;
    %atlas_search_batch_ids = $sbeams->selectTwoColumnHash($sql);

    print "       ".scalar(keys(%atlas_search_batch_ids))." loaded...\n";
  }


  #### Lookup and return sample_id
  if ($atlas_search_batch_ids{$proteomics_search_batch_id}) {
    return($atlas_search_batch_ids{$proteomics_search_batch_id});
  };

  die("ERROR: Unable to find '$proteomics_search_batch_id' in ".
      "atlas_search_batch_ids hash. This should never happen.");

} # end get_atlas_search_batch_id



###############################################################################
# get_spectrum_id --
###############################################################################
sub get_spectrum_id {
  my $METHOD = 'get_spectrum_id';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $sample_id = $args{sample_id}
    or die("ERROR[$METHOD]: Parameter sample_id not passed");
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");


  #### If we haven't loaded all spectrum_ids into the
  #### cache yet, do so
  our %spectrum_ids;
  our %processed_sample_ids;
  unless ($processed_sample_ids{$sample_id}) {
    print "\n[INFO] Loading spectrum_ids for sample_id $sample_id...\n";
    %spectrum_ids = ();
    $processed_sample_ids{$sample_id} = 1;
    my $sql = qq~
      SELECT sample_id,spectrum_name,spectrum_id
        FROM $TBAT_SPECTRUM
        WHERE sample_id=$sample_id
    ~;

    my $sth = $sbeams->get_statement_handle( $sql );
    my $num_ids =0;
    while ( my $row = $sth->fetchrow_arrayref() ) {
      #my $key = "$row->[0]-$row->[1]";
      $spectrum_ids{$row->[0]}{$row->[1]} = $row->[2];
      $num_ids++;
    }
    #my $num_ids = scalar(keys(%spectrum_ids));
    print "       $num_ids spectrum IDs loaded for sample_id $sample_id ...\n";
    #### Put a dummy entry in the hash so load won't trigger twice if
    #### table is empty at this point
    $spectrum_ids{DUMMY} = -1 unless $num_ids;
    #### Print out a few entries
    #my $i=0;
    #while (my ($key,$value) = each(%spectrum_ids)) {
    #  print "  spectrum_ids: $key = $value\n";
    #  last if ($i > 5);
    #  $i++;
    #}

  }


  #### Lookup and return spectrum_id
  #my $key = "$sample_id-$spectrum_name";
  #print "key = $key  spectrum_ids{key} = $spectrum_ids{$key}\n";
  if ($spectrum_ids{$sample_id}{$spectrum_name}) {
    return($spectrum_ids{$sample_id}{$spectrum_name});
  };

  #### Else we don't have it yet
  return();

} # end get_spectrum_id



###############################################################################
# insertSpectrumRecord --
###############################################################################
sub insertSpectrumRecord {
  my $METHOD = 'insertSpectrumRecord';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $sample_id = $args{sample_id}
    or die("ERROR[$METHOD]: Parameter sample_id not passed");
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $proteomics_search_batch_id = $args{proteomics_search_batch_id}
    or die("ERROR[$METHOD]: Parameter proteomics_search_batch_id not passed");
  my $chimera_level = $args{chimera_level} ;
  my $precursor_intensity = $args{precursor_intensity};
  my $total_ion_current = $args{total_ion_current};
  my $signal_to_noise = $args{signal_to_noise};
  my $retention_time_sec = $args{retention_time_sec};
  my $fragmentation_type_ids = $args{fragmentation_type_ids}
     or die("ERROR[$METHOD]: Parameter  fragmentation_type_ids not passed");

  my $fragmentation_type_id = '';

  #### Parse the name into components
  my ($fraction_tag,$start_scan,$end_scan);
  if ($spectrum_name =~ /^(.+)\.(\d+)\.(\d+)\.\d$/) {
    $fraction_tag = $1;
    $start_scan = $2;
    $end_scan = $3;
  }
  elsif($spectrum_name  =~ /^(.+)\..*\s+(\d+).*\d\)$/) {
    $fraction_tag = $1;
    $start_scan = $2;
    $end_scan = $2;
  }
  else {
    die("ERROR: Unable to parse fraction name from '$spectrum_name'");
  }

  my $scan = $start_scan;
  $scan =~ s/^0+//;
  if (defined $fragmentation_type_ids->{$fraction_tag}){
    if (defined $fragmentation_type_ids->{$fraction_tag}{'*'}){
       $fragmentation_type_id = $fragmentation_type_ids->{$fraction_tag}{'*'};
    }elsif(defined $fragmentation_type_ids->{$fraction_tag}{$scan}){
       $fragmentation_type_id = $fragmentation_type_ids->{$fraction_tag}{$scan};
    }else{
       print "WARNING: $spectrum_name fragmentation_type_id not found\n";
    }
  }

  my $spectrum_id ;
  if ($fhs->{spectrum}){
    my $fh = $fhs->{spectrum};
    $spectrum_id = $pk_counter->{spectrum};
    if ($chimera_level eq 'NULL'){
      $chimera_level = '';
    }
    print $fh "$spectrum_id\t$sample_id\t$spectrum_name\t$start_scan\t$end_scan\t".
                     "-1\t$precursor_intensity\t$total_ion_current\t\t\t\t\t\t$fragmentation_type_id\t".
                     "$chimera_level\t$signal_to_noise\t$retention_time_sec\n";
    $pk_counter->{spectrum}++;

  }else{
		#### Define the attributes to insert
		my %rowdata = (
			sample_id => $sample_id,
			spectrum_name => $spectrum_name,
			start_scan => $start_scan,
			end_scan => $end_scan,
			chimera_level => $chimera_level,
			scan_index => -1,
			precursor_intensity => $precursor_intensity,
			total_ion_current => $total_ion_current,
			signal_to_noise => $signal_to_noise,
			retention_time_sec=>$retention_time_sec
		);


		#### Insert spectrum record
		$spectrum_id = $sbeams->updateOrInsertRow(
			insert=>1,
			table_name=>$TBAT_SPECTRUM,
			rowdata_ref=>\%rowdata,
			PK => 'spectrum_id',
			return_PK => 1,
			verbose=>$VERBOSE,
			testonly=>$TESTONLY,
		);
  }

  #### Add it to the cache
  our %spectrum_ids;
  my $key = "$sample_id$spectrum_name";
  $spectrum_ids{$key} = $spectrum_id;
#  #### Get the spectrum peaks
#  my mz_intensitities = $self->getSpectrumPeaks(
#    proteomics_search_batch_id => $search_batch_id,
#    spectrum_name => $spectrum_name,
#    fraction_tag => $fraction_tag,
#  );

  return($spectrum_id);

} # end insertSpectrumRecord



###############################################################################
# get_data_location --
###############################################################################
sub get_data_location {
  my $METHOD = 'get_data_location';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $proteomics_search_batch_id = $args{proteomics_search_batch_id}
    or die("ERROR[$METHOD]: Parameter proteomics_search_batch_id not passed");

  #### If we haven't loaded all atlas_search_batch_ids into the
  #### cache yet, do so
  our %data_locations;

  unless (%data_locations) {
    print "[INFO] Loading all data_locations...\n" if ($VERBOSE);

    my $sql = qq~
      SELECT proteomics_search_batch_id,data_location || '/' || search_batch_subdir
        FROM $TBAT_ATLAS_SEARCH_BATCH
       WHERE record_status != 'D'
    ~;
    %data_locations = $sbeams->selectTwoColumnHash($sql);

    print "       ".scalar(keys(%data_locations))." loaded...\n" if ($VERBOSE);
  }


  #### Lookup and return data_location
  if ($data_locations{$proteomics_search_batch_id}) {
    return($data_locations{$proteomics_search_batch_id});
  };

  die("ERROR: Unable to find '$proteomics_search_batch_id' in ".
      "data_locations hash. This should never happen.");

} # end get_data_location


###############################################################################
# getSpectrumPeaks_Lib --
###############################################################################
sub getSpectrumPeaks_Lib {
  my $METHOD = 'getSpectrumPeaks_Lib';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $library_idx_file = $args{library_idx_file}
    or die("ERROR[$METHOD]: Parameter library_idx_file not passed");

  #### Infomational/problem message buffer, only printed if get fails
  my $buffer = '';
  #### Get the data_location of the spectrum

  $buffer .= "data_location = $library_idx_file\n";

  # If location does not begin with slash, prepend default dir.
  $buffer .= "library_location = $library_idx_file\n";

  use SBEAMS::PeptideAtlas::ConsensusSpectrum;
  my $consensus = new SBEAMS::PeptideAtlas::ConsensusSpectrum;
  $consensus->setSBEAMS($sbeams);
  my $peaks;

  my $comp_lib_idx_file = $library_idx_file;
  $comp_lib_idx_file =~ s/specidx/compspecidx/;
  my $off;
  if ( -e $comp_lib_idx_file ) {
    $log->debug( "Using compressed library $comp_lib_idx_file" );
    my $idx_line = `grep -m1 $args{spectrum_name} $comp_lib_idx_file`;
    chomp $idx_line;
    if ( !$idx_line ) {
      # spectra names are *not* supposed to have charges appended, but...
      my $trimmed_specname = $args{spectrum_name};
      $trimmed_specname =~ s/\.\d$//;
      $idx_line = `grep -m1 $trimmed_specname $comp_lib_idx_file`;
      chomp $idx_line;
      if ( $idx_line ) {
        $log->debug( "$trimmed_specname worked after removing .charge suffix" );
      } else {
        $log->error( "$trimmed_specname still doesn't work without .charge suffix" );
      }
    }

    if ( $idx_line ) {
      my @line = split( /\t/, $idx_line );
      $off = $line[4];
      my $len = $line[3];
      my $filename = $comp_lib_idx_file;
      $filename =~ s/.compspecidx/.sptxt.gz/;
      $peaks = $consensus->get_spectrum_peaks( file_path => $filename, 
                                               entry_idx => $off, 
                                                 rec_len => $len, 
                                                bgzipped => 1,
                                             denormalize => 0, 
                                              %args );

      $log->debug( "Compressed fetch failed" ) if !scalar( @{$peaks->{labels}} );
    } else {
      $log->debug( "unable to find $args{spectrum_name} in $comp_lib_idx_file" );
    }
  }

  if ( !$peaks  || !scalar( @{$peaks->{labels}} ) ) {
    $log->debug( "Using native library" );

    my $filename = $library_idx_file;

    if ( -e $comp_lib_idx_file && !-e $library_idx_file ) {
      print $sbeams->makeErrorText("Temporarily unable to open spectrum, this error has been logged.<BR>");
      my $libname = $comp_lib_idx_file;
      $libname =~ s/.compspecidx/.sptxt.gz/;
      $log->error( "unable to extract spectrum $off from $libname, and $filename does not exist" );
      return undef;
    } else {
      open (IDX, "<$filename") or die "cannot open $filename\n";
    }

    my $position;
    $spectrum_name =~ s/\.\d$//;
    while (my $line = <IDX>){
      chomp $line;
      if ($line =~ /$spectrum_name\t(\d+)/){
        $position = $1;
        last;
      }
    }
    close IDX; 

    if ($position eq ''){
      die ("ERROR: cannot find $spectrum_name in $filename");
    }
    $filename =~ s/.specidx/.sptxt/;
    if ( ! -e "$filename"){
      die ("ERROR: cannot find file $filename");
    }
    $filename =~ /.*\/(.*)/;

    # Dubious print statement!
    #  print "get spectrum from $1<BR>";

    $peaks = $consensus->get_spectrum_peaks( file_path => $filename, 
                                             entry_idx => $position, 
                                           denormalize => 0, 
                                            %args );
  }

  #### Read the spectrum data
  my @mz_intensities;
  for (my $i=0; $i< scalar @{$peaks->{masses}}; $i++) {
    push(@mz_intensities,[($peaks->{masses}[$i],$peaks->{intensities}[$i])]);
  }

  #### If there were no values, print diagnostics and return
  unless (@mz_intensities) {
    $buffer .= "ERROR: No peaks returned from extraction attempt<BR>\n";
    print $buffer;
    return;
  }
  #### Return result
  print "   ".scalar(@mz_intensities)." mass-inten pairs loaded\n"
    if ($VERBOSE);
  return(@mz_intensities);

} # end getSpectrumPeaks_Lib

###############################################################################
# getSpectrumPeaks_plotmsms --
###############################################################################
sub getSpectrumPeaks_plotmsms {
  my $METHOD = 'getSpectrumPeaks_plotmsms';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $proteomics_search_batch_id = $args{proteomics_search_batch_id}
    or die("ERROR[$METHOD]: Parameter proteomics_search_batch_id not passed");
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $fraction_tag = $args{fraction_tag}
    or die("ERROR[$METHOD]: Parameter fraction_tag not passed");
  my $parameters = $args{parameters};
  

  #### Infomational/problem message buffer, only printed if get fails
  my $buffer = '';

  #### Get the data_location of the spectrum
  my $data_location = $self->get_data_location(
    proteomics_search_batch_id => $proteomics_search_batch_id,
  );
  $buffer .= "data_location = $data_location<br>\n";
 

  ($data_location, $buffer) = $self->groom_data_location(
    data_location => $data_location,
    history_buffer => $buffer,
  );
  $buffer .= "data_location = $data_location<br>\n";

  my $filename;
  #### First try to fetch the spectrum from an mzXML file
  my $mzXML_filename;
  
  if($fraction_tag =~ /.mzML/){
    $mzXML_filename = "$data_location/$fraction_tag";
    if ( ! -e $mzXML_filename ){
      $mzXML_filename = "$data_location/$fraction_tag.mzML";
    }
  }else{
    $mzXML_filename = "$data_location/$fraction_tag.mzML";
  }

  if ( ! -e $mzXML_filename){
    $mzXML_filename .= ".gz";
  }

  if( ! -e $mzXML_filename){
     $mzXML_filename = "$data_location/$fraction_tag.mzXML";
  }

  if ( ! -e $mzXML_filename){
    $mzXML_filename .= ".gz";
  } 
 
  $buffer .= "INFO: Looking for '$mzXML_filename'<BR>\n";
  if ( -e $mzXML_filename ) {
    $buffer .= "INFO: Found '$mzXML_filename'<BR>\n";
    my $spectrum_number;
    if ($spectrum_name =~ /(\d+)\.(\d+)\.\d$/) {
      $spectrum_number = $1;
      $buffer .= "INFO: Spectrum number is $spectrum_number<BR>\n";
    } 
    my $org_request_method = $ENV{"REQUEST_METHOD"};
    my $org_query_string = $ENV{"QUERY_STRING"};
    $ENV{"REQUEST_METHOD"} = 'GET';
    $ENV{"QUERY_STRING"} = "Dta=$data_location/$fraction_tag/$spectrum_name.dta";
    my $content = `/proteomics/sw/tpp-latest/cgi-bin/plot-msms-js.cgi`;
    my (@ms1, @ms2);
		my @lines = split ("\n", $content);
		my ($ms1scanLabel, $selWinHigh,$selWinLow);
		my @ms1;
		my @ms2;
		my $ms2_flag =0;
		foreach my $line (@lines){
			if ($line =~ /var\s+ms1scanLabel.*=\s?"(.*)".*/){
				$ms1scanLabel = $1;
			}elsif($line =~ /var\s+selWinHigh.*=\s?([\d\.]+)/){
        $selWinHigh = $1;
      }elsif($line =~ /var\s+selWinLow.*=\s?([\d\.]+)/){
        $selWinLow = $1;
      }

			if ($line =~ /ms2peaks/){
				$ms2_flag = 1;
			}
			if ($line =~ /.*\[([\d\.]+),([\d\.]+)].*/){
				if ($ms2_flag){
					push(@ms2,[($1,$2)]);
				}else{
					push(@ms1,[($1,$2)]);
				}
			}
			if ($line =~ /.*\[[\d\.]+,[\d\.]+\]\];/){
				$ms2_flag = 0;
			}
		}
    $ENV{"REQUEST_METHOD"} = $org_request_method;
    $ENV{"QUERY_STRING"}  = $org_query_string;
    $parameters->{ms1scanLabel} = $ms1scanLabel;
    $parameters->{selWinLow} = $selWinLow;
    $parameters->{selWinHigh} = $selWinHigh;
    $parameters->{ms1peaks} = \@ms1;
    return @ms2;
  }
}
###############################################################################
# getSpectrumPeaks --
###############################################################################
sub getSpectrumPeaks {
  my $METHOD = 'getSpectrumPeaks';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $proteomics_search_batch_id = $args{proteomics_search_batch_id}
    or die("ERROR[$METHOD]: Parameter proteomics_search_batch_id not passed");
  my $spectrum_name = $args{spectrum_name}
    or die("ERROR[$METHOD]: Parameter spectrum_name not passed");
  my $fraction_tag = $args{fraction_tag}
    or die("ERROR[$METHOD]: Parameter fraction_tag not passed");


  #### Infomational/problem message buffer, only printed if get fails
  my $buffer = '';

  #### Get the data_location of the spectrum
  my $data_location = $self->get_data_location(
    proteomics_search_batch_id => $proteomics_search_batch_id,
  );
  $buffer .= "data_location = $data_location<br>\n";

  ($data_location, $buffer) = $self->groom_data_location(
    data_location => $data_location,
    history_buffer => $buffer,
  );
  $buffer .= "data_location = $data_location<br>\n";

  ### extracted into groom_data_location() -- can delete after 2/1/13
#--------------------------------------------------
#   # For absolute paths, leading slash is not being stored in
#   # data_location field of atlas_search_batch table. Until that is
#   # fixed, we have this nice kludge.
#   if ($data_location =~ /^regis/) {
#     $data_location = "/$data_location";
#   }
#   $buffer .= "data_location = $data_location<br>\n";
# 
#   # If location does not begin with slash, prepend default dir.
#   $buffer .= "data_location = $data_location\n";
#   unless ($data_location =~ /^\//) {
#     $data_location = $RAW_DATA_DIR{Proteomics}."/$data_location";
#   }
#   $buffer .= "data_location = $data_location<br>\n";
# 
#   #### Sometimes a data_location will be a specific xml file
#   if ($data_location =~ /^(.+)\/interac.+xml$/i) {
#     $data_location = $1;
#   }
# $buffer .= "data_location = $data_location<br>\n";
#-------------------------------------------------- 


  my $filename;


  #### First try to fetch the spectrum from an mzXML file
  my $mzXML_filename;
  
  if($fraction_tag =~ /.mzML/){
    $mzXML_filename = "$data_location/$fraction_tag";
    if ( ! -e $mzXML_filename ){
      $mzXML_filename = "$data_location/$fraction_tag.mzML";
    }
  }else{
    $mzXML_filename = "$data_location/$fraction_tag.mzML";
  }

  if ( ! -e $mzXML_filename){
    $mzXML_filename .= ".gz";
  }

  if( ! -e $mzXML_filename){
     $mzXML_filename = "$data_location/$fraction_tag.mzXML";
  }

  if ( ! -e $mzXML_filename){
    $mzXML_filename .= ".gz";
  } 
 
  $buffer .= "INFO: Looking for '$mzXML_filename'<BR>\n";
  if ( -e $mzXML_filename ) {
    $buffer .= "INFO: Found '$mzXML_filename'<BR>\n";
    my $spectrum_number;
    if ($spectrum_name =~ /(\d+)\.(\d+)\.\d$/) {
      $spectrum_number = $1;
      $buffer .= "INFO: Spectrum number is $spectrum_number<BR>\n";
    }

    #### If we have a spectrum number, try to get the spectrum data
    if ($spectrum_number) {
      #$filename = "$PHYSICAL_BASE_DIR/lib/c/Proteomics/getSpectrum/".
      #  "getSpectrum $spectrum_number $mzXML_filename |";
      $filename = "/proteomics/lmendoza/sw/misc/readmzXML_TPP600 -s ".
                  "$mzXML_filename $spectrum_number |"
    }

  }


  #### If there's no filename then try ISB SEQUEST style .tgz file
  unless ($filename) {
    my $tgz_filename = "$data_location/$fraction_tag.tgz";
    $buffer .= "INFO: Looking for '$data_location/$fraction_tag.tgz'<BR>\n";
    if ( -e $tgz_filename ) {
      $buffer .= "INFO: Found '$tgz_filename'<BR>\n";
      $spectrum_name = "./$spectrum_name";

      #### Since we didn't find that, try a Comet style access method
    } else {
      $tgz_filename = "$data_location/$fraction_tag.cmt.tar.gz";

      unless ( -e $tgz_filename ) {
	$buffer .= "WARNING: Unable to find Comet style .cmt.tar.gz<BR>\n";
	$buffer .= "ERROR: Unable to find spectrum archive to pull from<BR>\n";
	print $buffer;
	return;
      }
      $buffer .= "INFO: Found '$tgz_filename'\n";
    }


    $filename = "/bin/tar -xzOf $tgz_filename $spectrum_name.dta|";

    $buffer .= "Pulling from tarfile: $tgz_filename<BR>\n";
    $buffer .= "Extracting: $filename<BR>\n";
  }


  #### Try to open the spectrum for reading
  unless (open(DTAFILE,$filename)) {
    $buffer .= "ERROR Cannot open '$filename'!!<BR>\n";
    print $buffer;
    return;
  }

  #### Read in but ignore header line if a dta file
  if ($filename =~ m#/bin/tar#) {
    my $headerline = <DTAFILE>;
    unless ($headerline) {
      $buffer .= "ERROR: No result returned from extraction attempt<BR>\n";
      print $buffer;
      return;
    }
  }

  #### Read the spectrum data
  my @mz_intensities;
  while (my $line = <DTAFILE>) {
    chomp($line);
    next if($line !~ /mass.*inten/);
    #my @values = split(/\s+/,$line);
    $line =~ /mass\s+(\S+)\s+inten\s+(\S+)/;
    push(@mz_intensities,[($1,$2)]);
  }
  close(DTAFILE);

  #### If there were no values, print diagnostics and return
  unless (@mz_intensities) {
    $buffer .= "ERROR: No peaks returned from extraction attempt<BR>\n";
    print $buffer;
    return;
  }
  #### Return result
  print "   ".scalar(@mz_intensities)." mass-inten pairs loaded\n"
    if ($VERBOSE);
  return(@mz_intensities);

} # end getSpectrumPeaks


###############################################################################
# groom_data_location --
###############################################################################
sub groom_data_location {
  my $METHOD = 'groom_data_location';
  my $self = shift || die ("self not passed");
  my %args = @_;
  my $data_location = $args{data_location};
  my $history_buffer = $args{history_buffer} || '';

  # For absolute paths, leading slash is not being stored in
  # data_location field of atlas_search_batch table. Until that is
  # fixed, we have this nice kludge.
  if ($data_location =~ /^regis/) {
    $data_location = "/$data_location";
  }
  $history_buffer .= "data_location = $data_location\n";

  # If location does not begin with slash, prepend default dir.
  $history_buffer .= "data_location = $data_location\n";
  unless ($data_location =~ /^\//) {
    $data_location = $RAW_DATA_DIR{Proteomics}."/$data_location";
  }
  $history_buffer .= "data_location = $data_location\n";

  #### Sometimes a data_location will be a specific xml file
  if ($data_location =~ /^(.+)\/interac.+xml$/i) {
    $data_location = $1;
  }

  $history_buffer .= "data_location = $data_location\n";

  return ($data_location, $history_buffer);
}


###############################################################################
# get_ptm_spectrum_identification_id --
###############################################################################
sub get_ptm_spectrum_identification_id {
  my $METHOD = 'get_ptm_spectrum_identification_id';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $spectrum_identification_id = $args{spectrum_identification_id}
    or die("ERROR[$METHOD]: Parameter spectrum_identification_id not passed");
  my $atlas_search_batch_id = $args{atlas_search_batch_id}
    or die("ERROR[$METHOD]: Parameter atlas_search_batch_id not passed");
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");

  #### If we haven't loaded all spectrum_identification_ids into the
  #### cache yet, do so
  our %ptm_spectrum_identification_ids;
  unless (%ptm_spectrum_identification_ids){
    print "\n[INFO] Loading all spectrum_identification_ids ...\n";
    my $sql = qq~
      SELECT SI.atlas_search_batch_id, SI.SPECTRUM_IDENTIFICATION_id 
        FROM $TBAT_SPECTRUM_PTM_IDENTIFICATION SPI 
        JOIN $TBAT_SPECTRUM_IDENTIFICATION SI ON (SI.SPECTRUM_IDENTIFICATION_id = SPI.SPECTRUM_IDENTIFICATION_ID)
        JOIN $TBAT_MODIFIED_PEPTIDE_INSTANCE MPI
             ON ( SI.modified_peptide_instance_id = MPI.modified_peptide_instance_id )
        JOIN $TBAT_PEPTIDE_INSTANCE PEPI
             ON ( MPI.peptide_instance_id = PEPI.peptide_instance_id )
       WHERE PEPI.atlas_build_id = '$atlas_build_id'
    ~;

    my $sth = $sbeams->get_statement_handle( $sql );
    my $n = 0;
    #### Create a hash out of it
    while ( my $row = $sth->fetchrow_arrayref() ) {
      $ptm_spectrum_identification_ids{$row->[0]}{$row->[1]} = 1;
      $n++;
    }
    print "       $n loaded...\n";
  }
  #### Lookup and return spectrum_id
  if ( $ptm_spectrum_identification_ids{$atlas_search_batch_id}{$spectrum_identification_id}){
    return 1; 
  };

  return();

} # end get_ptm_spectrum_identification_id
###############################################################################
# get_spectrum_identification_id --
###############################################################################
sub get_spectrum_identification_id {
  my $METHOD = 'get_spectrum_identification_id';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $spectrum_id = $args{spectrum_id}
    or die("ERROR[$METHOD]: Parameter spectrum_id not passed");
  my $atlas_search_batch_id = $args{atlas_search_batch_id}
    or die("ERROR[$METHOD]: Parameter atlas_search_batch_id not passed");
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");

  #### If we haven't loaded all spectrum_identification_ids into the
  #### cache yet, do so
  our %spectrum_identification_ids;
  unless (%spectrum_identification_ids){
    print "\n[INFO] Loading all spectrum_identification_ids ...\n";
    my $sql = qq~
      SELECT SI.atlas_search_batch_id,SI.spectrum_id, SI.spectrum_identification_id
        FROM $TBAT_SPECTRUM_IDENTIFICATION SI
        JOIN $TBAT_MODIFIED_PEPTIDE_INSTANCE MPI
             ON ( SI.modified_peptide_instance_id = MPI.modified_peptide_instance_id )
        JOIN $TBAT_PEPTIDE_INSTANCE PEPI
             ON ( MPI.peptide_instance_id = PEPI.peptide_instance_id )
       WHERE PEPI.atlas_build_id = '$atlas_build_id'
    ~;

    my $sth = $sbeams->get_statement_handle( $sql );
    my $n = 0;
    #### Create a hash out of it
    while ( my $row = $sth->fetchrow_arrayref() ) {
      $spectrum_identification_ids{$row->[0]}{$row->[1]} = $row->[2];
      $n++;
    }

    print "       $n loaded...\n";
  }
  #### Lookup and return spectrum_identification_id
  if ( $spectrum_identification_ids{$atlas_search_batch_id}{$spectrum_id}){
    return $spectrum_identification_ids{$atlas_search_batch_id}{$spectrum_id}; 
  };

  return();

} # end get_spectrum_identification_id

###############################################################################
# insertSpectrumIdentificationRecord --
###############################################################################
sub insertSpectrumIdentificationRecord {
  my $METHOD = 'insertSpectrumIdentificationRecord';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $modified_peptide_instance_id = $args{modified_peptide_instance_id}
    or die("ERROR[$METHOD]:Parameter modified_peptide_instance_id not passed");
  my $spectrum_id = $args{spectrum_id}
    or die("ERROR[$METHOD]: Parameter spectrum_id not passed");
  my $atlas_search_batch_id = $args{atlas_search_batch_id}
    or die("ERROR[$METHOD]: Parameter atlas_search_batch_id not passed");
  my $massdiff = $args{massdiff};

  my $probability = $args{probability};
  die("ERROR[$METHOD]: Parameter probability not passed") if($probability eq '');


  #### Define the attributes to insert
  my %rowdata = (
    modified_peptide_instance_id => $modified_peptide_instance_id,
    spectrum_id => $spectrum_id,
    atlas_search_batch_id => $atlas_search_batch_id,
    probability => $probability,
    massdiff => $massdiff,
  );

  
  #### Insert spectrum identification record
  my $spectrum_identification_id = $sbeams->updateOrInsertRow(
    insert=>1,
    table_name=>$TBAT_SPECTRUM_IDENTIFICATION,
    rowdata_ref=>\%rowdata,
    PK => 'spectrum_identification_id',
    return_PK => 1,
    verbose=>$VERBOSE,
    testonly=>$TESTONLY,
  );


  #### Add it to the cache
  our %spectrum_identification_ids;
  my $key = "$modified_peptide_instance_id - $spectrum_id - $atlas_search_batch_id";
  $spectrum_identification_ids{$key} = $spectrum_identification_id;

  return($spectrum_identification_id);

} # end insertSpectrumIdentificationRecord


###############################################################################
# insertSpectrumPTMIdentificationRecord --
###############################################################################
sub insertSpectrumPTMIdentificationRecord {
  my $METHOD = 'insertSpectrumPTMIdentificationRecord';
  my $self = shift || die ("self not passed");
  my %args = @_;

  my $spectrum_identification_id = $args{spectrum_identification_id}
    or die("ERROR[$METHOD]: Parameter spectrum_identification_id not passed");
  my $ptm_sequence = $args{ptm_sequence}
    or die("ERROR[$METHOD]: Parameter ptm_sequence not passed");
  my $ptm_lability = $args{ptm_lability} 
    or die("ERROR[$METHOD]: Parameter ptm_lability not passed");

  #### Define the attributes to insert
  my @ptm_sequences = split(",", $ptm_sequence);
  my @ptm_labilities = split(",", $ptm_lability); 
  my $spectrum_ptm_identification_id;

  for (my $i=0; $i<=$#ptm_sequences;$i++){
    my $sequence = $ptm_sequences[$i];
    my $lability = $ptm_labilities[$i];

		$sequence =~ /\[(\S+)\](.*)/;
		my $ptm_type = $1;
		$sequence = $2;
		my %rowdata = (
			ptm_sequence => $sequence,
			spectrum_identification_id => $spectrum_identification_id,
			ptm_type => $ptm_type,
      ptm_lability => $lability
		);

		#### Insert spectrum PTM identification record
		$spectrum_ptm_identification_id = $sbeams->updateOrInsertRow(
			insert=>1,
			table_name=>$TBAT_SPECTRUM_PTM_IDENTIFICATION,
			rowdata_ref=>\%rowdata,
			PK => 'spectrum_ptm_identification_id',
			return_PK => 1,
			verbose=>$VERBOSE,
			testonly=>$TESTONLY,
		);
  }
  return($spectrum_ptm_identification_id);

} # end insertSpectrumPTMIdentificationRecord



###############################################################################
# loadSpectrum_Fragmentation_Type -- Loads all Spectrum_Fragmentation_Type for specified build
###############################################################################
sub loadSpectrum_Fragmentation_Type {
  my $METHOD = 'loadSpectrum_Fragmentation_Type';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");

  my $sql = qq~
     SELECT FRAGMENTATION_TYPE, FRAGMENTATION_TYPE_ID
     FROM $TBAT_FRAGMENTATION_TYPE
  ~;
  my %fragmentation_type_ids = $sbeams->selectTwoColumnHash($sql);

  $sql = qq~
    SELECT DISTINCT ASB.DATA_LOCATION, COALESCE(E.fragmentation_type_ids,S.fragmentation_type_ids)
    FROM $TBAT_SPECTRUM SP
    JOIN $TBAT_ATLAS_SEARCH_BATCH ASB ON (SP.SAMPLE_ID = ASB.SAMPLE_ID)
    JOIN $TBAT_ATLAS_BUILD_SEARCH_BATCH ABSB ON (ABSB.ATLAS_SEARCH_BATCH_ID  = ASB.ATLAS_SEARCH_BATCH_ID )
    JOIN $TBAT_SAMPLE  S ON (ABSB.SAMPLE_ID = S.SAMPLE_ID)
    JOIN $TBPR_SEARCH_BATCH PSB ON (PSB.SEARCH_BATCH_ID = ASB.PROTEOMICS_SEARCH_BATCH_ID)
    JOIN $TBPR_PROTEOMICS_EXPERIMENT E ON (E.EXPERIMENT_ID = PSB.EXPERIMENT_ID)
    WHERE ABSB.ATLAS_BUILD_ID = $atlas_build_id
    AND SP.FRAGMENTATION_TYPE_ID IS NULL
  ~;
  
  my %directories = $sbeams->selectTwoColumnHash($sql);
  foreach my $dir (keys %directories){
    my $sql =qq~
     SELECT  SP.SPECTRUM_NAME, SP.SPECTRUM_ID
      FROM $TBAT_SPECTRUM SP
      JOIN $TBAT_ATLAS_SEARCH_BATCH ASB ON (SP.SAMPLE_ID = ASB.SAMPLE_ID)
      JOIN $TBAT_ATLAS_BUILD_SEARCH_BATCH ABSB ON (ABSB.ATLAS_SEARCH_BATCH_ID  = ASB.ATLAS_SEARCH_BATCH_ID )
      WHERE ABSB.ATLAS_BUILD_ID = $atlas_build_id
      AND SP.FRAGMENTATION_TYPE_ID IS NULL
      AND ASB.DATA_LOCATION = '$dir'
    ~;
    my @rows = $sbeams->selectSeveralColumns($sql);
    my %scan2spectrum_id=();
    my %data = ();
    foreach my $row (@rows){
      my ($spectrum_name, $id) = @$row;
      $spectrum_name =~ /(.*)\.(\d+)\.\d+\.\d+/;
      my $specfile = $1;
      my $scan = $2;
      $scan =~ s/^0+//;
      $scan2spectrum_id{$specfile}{$scan} = $id;
    }

    ## 1. check the data folder for fragmentation_types.tsv files
    ## 2. if not found or empty, use the type from proteomics experiment table, 
    #     if more than one type, print warning
    my $data_directory = "$dir/data";
    $data_directory = "/regis/sbeams/archive/$dir/data" if ($dir !~ /regis/);
    if (! -d "$data_directory"){
      print "ERROR cannot find $data_directory\n";
      next;
    }
    opendir ( DIR, $data_directory ) || die "Error in opening dir $data_directory\n";
    my @fragmentation_types_files = ();
    while(my $filename = readdir(DIR)) {
      if ($filename =~ /(.*).fragmentation_types.tsv/){
        $filename ="$data_directory/$filename";
        push @fragmentation_types_files ,$filename if (-s $filename);
      }
    }
		closedir(DIR); 
	  if (@fragmentation_types_files){
      foreach my $filename (@fragmentation_types_files){	
         if (open(F, "<$filename")){
            print "\t$filename "; 
            $filename =~ /^.*\/(.*).fragmentation_types.tsv$/;
            my $specfile = $1;
            if (not defined $scan2spectrum_id{$specfile}){
              #print "no update\n";
              next;
            }else{
              print "\n";
            }
            my %fragmentation_types =();
            foreach my $line(<F>){
              if ($line =~ /(unknown|\?\?)/i){ 
                 my $type = $directories{$dir};
								 if ($type && $type !~/,/){
									 $self->updateSpectrum_Fragmentation_Type(   scan2spectrum_id =>[values %{$scan2spectrum_id{$specfile}}],
                                                               fragmentation_type_id => $type);
								 }else{
									 print "WARNING: no update for $data_directory\n";
								 }
                 last;
              }
              if ($line =~ /^(\-1|\*)\s+(.*)/){
                my $type = $2;
                die "ERROR $line\n\tno fragmentation_type_id found for type '$type'\n" if (not defined $fragmentation_type_ids{$type});
                $self->updateSpectrum_Fragmentation_Type(   scan2spectrum_id =>[values %{$scan2spectrum_id{$specfile}}],
                                                     fragmentation_type_id => $fragmentation_type_ids{$type});
                last;
              }else{
                 $line =~ /^(\d+)\s+(.*)$/;
                 my $scan = $1;
                 my $type = $2;
                 die "ERROR $line\n\tno fragmentation_type_id found for type '$type'\n" if (not defined $fragmentation_type_ids{$type});      
                 next if (not defined $scan2spectrum_id{$specfile}{$scan});
                  
                 $fragmentation_types{$fragmentation_type_ids{$type}}{$scan2spectrum_id{$specfile}{$scan}} =1;
              } 
            }
            foreach my $id(keys %fragmentation_types){
               print "$id\t";
               print join("," ,keys %{$fragmentation_types{$id}} ) ."\n";;
               $self -> updateSpectrum_Fragmentation_Type( scan2spectrum_id =>[keys %{$fragmentation_types{$id}}],
                                                     fragmentation_type_id => $id);
            }
         }else{
           print "ERROR: failed to open $filename\n";
           next;
         }
      }
		}else{
       ## check if it is tof
       my $type = $directories{$dir};
       if ($type && $type !~/,/){
          foreach my $specfile (keys %scan2spectrum_id){
             print "\t$data_directory/$specfile, no fragmentation_types.tsv file\n";
             $self->updateSpectrum_Fragmentation_Type(   scan2spectrum_id =>[values %{$scan2spectrum_id{$specfile}}],
                                                     fragmentation_type_id => $type);
          }
       }else{
         print "WARNING: no update for $data_directory\n";
       }
    }
  }
}

sub updateSpectrum_Fragmentation_Type {
  my $METHOD = 'updateSpectrum_Fragmentation_Type';
  my $self = shift || die ("self not passed");
  my %args = @_;
  my @ids = @{$args{scan2spectrum_id}};
  my $fragmentation_type_id = $args{fragmentation_type_id};
  my $n= scalar @ids;

  for (my $i=0; $i<$n; $i+=500){
    my @list = ();
    for (my $j=$i;$j<$i+500 && $j<$n;$j++){
      push @list, $ids[$j];
    }
    my $str = join(",", @list);
    my $sql = qq~
			UPDATE $TBAT_SPECTRUM 
			SET FRAGMENTATION_TYPE_ID = $fragmentation_type_id
			WHERE SPECTRUM_ID IN ($str)
    ~;
    $sbeams->executeSQL($sql);
  }
  print "\t$n spectra updated with type $fragmentation_type_id\n";

}
sub loadSpectrum_Fragmentation_Type_old {
  my $METHOD = 'loadBuildSpectra';
  my $self = shift || die ("self not passed");
  my %args = @_;

  #### Process parameters
  my $atlas_build_id = $args{atlas_build_id}
    or die("ERROR[$METHOD]: Parameter atlas_build_id not passed");

  my $sql = qq~
    SELECT DISTINCT ASB.DATA_LOCATION, COALESCE(E.fragmentation_type_ids,S.fragmentation_type_ids)
    FROM $TBAT_SPECTRUM SP
    JOIN $TBAT_ATLAS_SEARCH_BATCH ASB ON (SP.SAMPLE_ID = ASB.SAMPLE_ID)
    JOIN $TBAT_ATLAS_BUILD_SEARCH_BATCH ABSB ON (ABSB.ATLAS_SEARCH_BATCH_ID  = ASB.ATLAS_SEARCH_BATCH_ID )
    JOIN $TBAT_SAMPLE  S ON (ABSB.SAMPLE_ID = S.SAMPLE_ID)
    JOIN $TBPR_SEARCH_BATCH PSB ON (PSB.SEARCH_BATCH_ID = ASB.PROTEOMICS_SEARCH_BATCH_ID)
    JOIN $TBPR_PROTEOMICS_EXPERIMENT E ON (E.EXPERIMENT_ID = PSB.EXPERIMENT_ID)
    JOIN $TBPR_INSTRUMENT I ON (I.INSTRUMENT_ID = S.INSTRUMENT_MODEL_ID)
    JOIN $TBPR_INSTRUMENT_TYPE IT ON (I.INSTRUMENT_TYPE_ID = IT.INSTRUMENT_TYPE_ID)
    WHERE ABSB.ATLAS_BUILD_ID = $atlas_build_id
    AND SP.FRAGMENTATION_TYPE_ID IS NULL
  ~;
  
  my %directories = $sbeams->selectTwoColumnHash($sql);
  my $commit_interval = 50;
  $sbeams->initiate_transaction();
  my ($start, $diff);
 
	my $cnt_update = 0;
  foreach my $dir (keys %directories){
    my $ids = $directories{$dir};

    $start = [gettimeofday];
		my $sql = qq~
			SELECT SP.SPECTRUM_ID,
						 SP.SPECTRUM_NAME, 
						 ASB.DATA_LOCATION,
						 ASB.SEARCH_BATCH_SUBDIR,
						 IT.INSTRUMENT_TYPE_NAME
			FROM $TBAT_SPECTRUM SP
			JOIN $TBAT_ATLAS_SEARCH_BATCH ASB ON (SP.SAMPLE_ID = ASB.SAMPLE_ID)
			JOIN $TBAT_ATLAS_BUILD_SEARCH_BATCH ABSB ON (ABSB.ATLAS_SEARCH_BATCH_ID  = ASB.ATLAS_SEARCH_BATCH_ID )
			JOIN $TBAT_SAMPLE  S ON (ABSB.SAMPLE_ID = S.SAMPLE_ID)
			JOIN $TBPR_INSTRUMENT I ON (I.INSTRUMENT_ID = S.INSTRUMENT_MODEL_ID)
			JOIN $TBPR_INSTRUMENT_TYPE IT ON (I.INSTRUMENT_TYPE_ID = IT.INSTRUMENT_TYPE_ID)
			WHERE ABSB.ATLAS_BUILD_ID = $atlas_build_id 
			AND SP.FRAGMENTATION_TYPE_ID IS NULL
      AND ASB.DATA_LOCATION = '$dir' 
			ORDER BY SP.SPECTRUM_NAME, DATA_LOCATION
		~;
		print "Loading SPECTRUM_ID in $dir \n";
		my @rows = $sbeams->selectSeveralColumns($sql);
		my %spectrum=();
		my %fragmentation_type=();
		my $pre_file='';
		my $cnt = 0;
    if ($ids ne '' && $ids !~ /,/){
       foreach my $row (@rows){
         my ($spectrum_id, $spectrum_name,$data_location,$subdir, $instrument_type_name)= @$row;
         my %rowdata = (
           fragmentation_type_id => $ids,
         );
         my $response = $sbeams->updateOrInsertRow(
           update=>1,
           table_name=>$TBAT_SPECTRUM,
           rowdata_ref=>\%rowdata,
           PK => 'spectrum_id',
           PK_value=> $spectrum_id,
           return_PK => 1,
           verbose=>$VERBOSE,
           testonly=> $TESTONLY
        );
        if($cnt_update % 1000 == 0){
           print "$cnt_update...";
        }
        $cnt_update++;
        $sbeams->commit_transaction() if($cnt_update > $commit_interval && $cnt_update % $commit_interval);

       }
       next;
    }
   
     
		foreach my $row (@rows){
			my ($spectrum_id, $spectrum_name,$data_location,$subdir, $instrument_type_name)= @$row; 
			$spectrum_name=~ /^(.*)\.\d+\.(\d+)\.\d+$/;
			my $filename = $1;
			my $scan = $2;
			$scan =~ s/^0+//g;
			#next if ($data_location =~ /small_intestine_ileum_6w_m1_SCX_QstarElit/);
			#next if ($filename =~ /fraction1_20051215/);
			my $file ="/regis/sbeams/archive/$data_location/$subdir/$filename.mzML";
			chomp $file;
			if(! -e $file){
				$file ="/regis/sbeams/archive/$data_location/$subdir/$filename.mzXML";
				if(! -e $file){
					$file ="/regis/sbeams/archive/$data_location/$subdir/$filename.mzML.gz";
					if(! -e $file){
						 $file ="/regis/sbeams/archive/$data_location/$subdir/$filename.mzXML.gz";
						 if ( ! -e $file){
							 print "cannot find mzXML/mzML file: /regis/sbeams/archive/$data_location/$subdir/$filename\n";
               next;
						 }
					}
				}
			}

			my $type = 0;
			## decide type 4 
			if ($instrument_type_name  =~ /tof/i){$type= 4;};
      if ($ids !~ /,/ && $ids ne ''){
         $type = $ids;
      }
      if ($file =~ /lbrill.Hs_hESC_NSC_phospho/){
        if( $file =~ /ETD/){
          $type = 6;
        }else{
          $type = 5;
        }
      }
       

			## if not type 4, read file
			if ($pre_file ne $file && ! $type ){ 
				%fragmentation_type = ();
				#print "$file\n";
        $start = [gettimeofday];
				get_fragmentation_type( file => $file,
															fragmentation_type => \%fragmentation_type);
        print "read $file\n";
				#print scalar keys %fragmentation_type , "\n";
				#if(scalar keys %fragmentation_type == 0){
			 	#	print "no update: $file\n";
				#}
			}
			$pre_file = $file;
			if( $type == 4 || defined $fragmentation_type{$scan}){ 
				if(defined $fragmentation_type{$scan} and $type != 4){
					$type = $fragmentation_type{$scan};
				}
				my %rowdata = (
					 fragmentation_type_id => $type,
				);
				my $response = $sbeams->updateOrInsertRow(
					 update=>1,
					 table_name=>$TBAT_SPECTRUM,
					 rowdata_ref=>\%rowdata,
					 PK => 'spectrum_id',
					 PK_value=> $spectrum_id,
					 return_PK => 1,
					 verbose=>$VERBOSE,
					 testonly=> $TESTONLY
				);
				if($cnt_update % 1000 == 0){
					print "$cnt_update...";
				}
				$cnt_update++;
        $sbeams->commit_transaction() if($cnt_update > $commit_interval && $cnt_update % $commit_interval);
			}
		} 
     
    $sbeams->commit_transaction() if ! ($commit_interval % $cnt_update);
		$cnt++;
    print "\n$cnt_update of $cnt updated\n";
  }
  $sbeams->reset_dbh();
}

sub get_fragmentation_type {
  my %args = @_;
  my $file = $args{file};
  my $fragmentation_type = $args{fragmentation_type};
  my $fh;
  if($file =~ /\.gz/){ 
    return if($file =~ /HapMapQuantitativeProteome/);
   	open ($fh, "zcat $file|") or die "cannot open $file\n";
  }else{
    open ($fh, "<$file") or die "cannot open $file\n";
  }
	my %filterstr = ();
  my %instrumentConfiguration =();
	##  1 HR IT CID  (FTICR or Orbitrap)
	##  2 HR IT ETD (FTICR or Orbitrap)
	##  3 HR IT HCD (FTICR or Orbitrap)
	##  4 HR Q-TOF  (Agilent Q-TOF or SCIEX 5600 or QSTAR)
	##  5 LR IT CID (QTRAP 4000, 5500, LTQ, LCQ, Equire, etc.)
	##  6 LR IT ETD (LTQ)
  my ($insconf,$insconfid);
	while (my $line = <$fh>){
    ## below parsing needs to be refined, cause I am not sure if some tags will be missing or have differt names.
		if($line =~ /<instrumentConfigurationList/){  # mzML
			while ($line !~ /<\/instrumentConfigurationList/){
				$line = <$fh>;
				if($line =~ /instrumentConfiguration id="([^"]+)"/){
					$insconf = $1;
				}elsif($line =~ /<analyzer/){
					$line = <$fh>;
					if ($line =~ /.*name="([^"]+)"/){
						$instrumentConfiguration{$insconf} = $1;
						$insconf = '';
					}
				}
			}
      next;
    }
    if($line =~ /<msInstrument id="([^"]+)/){ #mzXML
      $insconfid = $1;
      while ($line !~ /<scan/){
        $line = <$fh>;
        if($line =~ /.*category="msMassAnalyzer" value="([^"]+)"/){
          $instrumentConfiguration{$insconfid} = $1;
        }
        $insconf = '';
      }
      next;
    }elsif($line =~ /<msInstrument>/){
       $insconfid = 'all';
       while ($line !~ /<\/msInstrument/){
        $line = <$fh>;
        if($line =~ /.*category="msMassAnalyzer" value="([^"]+)"/){
          $instrumentConfiguration{$insconfid} = $1;
        }
        $insconf = '';
      }
      next;
    }

		if($line =~ /<spectrum index="(\d+)".*/){ ## mzML 
	    my ($ms1,$scan, $insconf, $insid,$analyzer, $activation);
			$scan = $1 + 1;
      if($line =~ /scan=(\d+)/){
        $scan = $1;
      }
      while ($line !~/<\/spectrum/){
        $line = <$fh>;
        if($line =~ /ms level" value="1"/){
          last;
        }
				if($line =~ /name="filter string" value="(.*)"/){
					my $str = $1;
					my $type = '';
					if($str =~ /FTMS.*\@cid/){
						$type = 1;
					}elsif($str =~ /FTMS.*\@etd/){
						$type = 2;
					}elsif($str =~ /ITMS.*\@etd/){
						$type = 6;
					}elsif($str =~ /ITMS.*\@cid/){
						$type = 5;
					}elsif($str =~ /FTMS.*\@hcd/){
						$type = 3;
					}
					$fragmentation_type->{$scan} = $type;
				}elsif($line =~ /scan instrumentConfigurationRef="([^"]+)"/){
					$insid = $1;
				}elsif($line =~ /<activation>/ && not defined $fragmentation_type ->{$scan} ){
           if( $insid eq ''){
             if (scalar keys %instrumentConfiguration == 1){
               my @insids = keys %instrumentConfiguration;
               $insid = $insids[0];
             }
           }
 					 while ($line !~ /dissociation/ && $line !~ /binaryDataArrayList/){
						 $line = <$fh>;
					 }
					 $line =~ /name="([^"]+)"/;
           $activation = $1;
           if ($insid && $activation){
             $analyzer = $instrumentConfiguration{$insid};
             $fragmentation_type->{$scan} = get_type_id($analyzer, $activation);
             #print "$analyzer,$activation, ". $fragmentation_type ->{$scan} ."\n";
           }
        }
      }
    }elsif($line =~ /<scan num="(\d+)"/){## mzXML
	    my ($ms1,$scan, $insconf, $insid,$analyzer, $activation);
      $scan = $1;
      while ($line !~/<\/scan/){
        $line = <$fh>;
        if($line =~ /msLevel="1"/){
          last;
        }
          
        if($line =~ /filterLine="(.*)"/){
          my $str = $1;
          my $type = '';
          if($str =~ /FTMS.*\@cid/){
            $type = 1;
          }elsif($str =~ /FTMS.*\@etd/){
            $type = 2;
          }elsif($str =~ /ITMS.*\@etd/){
            $type = 6;
          }elsif($str =~ /ITMS.*\@cid/){
            $type = 5;
          }elsif($str =~ /FTMS.*\@hcd/){
            $type = 3;
          }
          $fragmentation_type->{$scan} = $type;
        }elsif($line =~ /msInstrumentID="([^"]+)"/){
           $insid = $1;
        }elsif($line =~ /activationMethod="(\w+)"/){
           $activation = $1;
        }elsif($line =~ /<peak/ && not defined $fragmentation_type ->{$scan}){
          if($insid eq ''){
            $insid = 'all';
          }
          if(! $activation){
            $activation = 'CID';
          }
          #print "$insid, $instrumentConfiguration{$insid} , $activation\n";
          if(defined $instrumentConfiguration{$insid}){
						$analyzer = $instrumentConfiguration{$insid};
						$fragmentation_type->{$scan} = get_type_id($analyzer, $activation);
          }
        }
      }
    }
  }
  close $fh;

}
###############################################################################
# get_atlas_build_directory  --  get atlas build directory
# @param atlas_build_id
# @return atlas_build:data_path
###############################################################################
sub get_atlas_build_directory
{
    my %args = @_;
    my $atlas_build_id = $args{atlas_build_id} or die "need atlas build id";
    my $path;

    my $sql = qq~
        SELECT data_path
        FROM $TBAT_ATLAS_BUILD
        WHERE atlas_build_id = '$atlas_build_id'
        AND record_status != 'D'
    ~;

    ($path) = $sbeams->selectOneColumn($sql) or
        die "\nERROR: Unable to find the data_path in atlas_build record".
        " with $sql\n\n";

    ## get the global variable PeptideAtlas_PIPELINE_DIRECTORY
    my $pipeline_dir = $CONFIG_SETTING{PeptideAtlas_PIPELINE_DIRECTORY};

    $path = "$pipeline_dir/$path";

    ## check that path exists
    unless ( -e $path)
    {
        die "\n Can't find path $path in file system.  Please check ".
        " the record for atlas_build with atlas_build_id=$atlas_build_id";

    }

    return $path;
}

sub get_type_id{
  my $analyzer = shift;
  my $activation = shift;
  my $type = '';

 if($activation =~ /(electron transfer|ETD)/i){
	 if ($analyzer !~ /(orbi|FT|fourier)/i && $analyzer !~ /tof/i ){
		 $type = 6;
	 }elsif($analyzer =~ /tof/i){
			$type = 4; 
	 }else{
		 $type = 2;
	 }
 }elsif ($activation =~ /(collision.induced|CID)/i){
	 if ($analyzer !~ /(orbi|FT|fourier)/i ){
		 $type = 5;
	 }elsif($analyzer =~ /tof/i){
			$type = 4;
	 }else{
		 $type = 1;
	 }
 }elsif($activation =~ /(high.energy collision.induced|HCD)/i){
	 $type = 3;
 }
  return $type;
}
###############################################################################
=head1 BUGS

Please send bug reports to SBEAMS-devel@lists.sourceforge.net

=head1 AUTHOR

Eric W. Deutsch (edeutsch@systemsbiology.org)

=head1 SEE ALSO

perl(1).

=cut
###############################################################################
1;

__END__
###############################################################################
###############################################################################
###############################################################################
