#!/usr/bin/env perl

use lib $ENV{"DADA_ROOT"}."/bin";

use strict;
use warnings;
use threads;
use threads::shared;
use File::Basename;
use Time::Local;
use Time::HiRes qw(usleep);
use Dada;
use Mopsr;

#
# Global Variable Declarations
#
our $dl;
our $daemon_name;
our %cfg;
our %bf_cfg;
our %bp_cfg;
our %bp_ct;
our $quit_daemon : shared;
our $warn;
our $error;
our $coarse_nchan;
our $hires;

#
# Initialize global variables
#
%cfg = Mopsr::getConfig();
%bf_cfg = Mopsr::getConfig("bf");
%bp_cfg = Mopsr::getConfig("bp");
%bp_ct = Mopsr::getCornerturnConfig("bp");
$dl = 1;
$daemon_name = Dada::daemonBaseName($0);
$warn = ""; 
$error = ""; 
$quit_daemon = 0;
$coarse_nchan = 32;
if (($cfg{"CONFIG_NAME"} =~ m/320chan/) || ($cfg{"CONFIG_NAME"} =~ m/312chan/))
{
  $hires = 1;
}
else
{
  $hires = 0;
}

# Autoflush STDOUT
$| = 1;


# 
# Function Prototypes
#
sub main();
sub getObsAge($);
sub markObsState($$$);
sub processCorrObservation($$$);
sub processTbObservation($$$);
sub processFbObservation($$$);
sub processArchive($$$);
sub makePlotsFromArchives($$$$$$);
sub removeOldPngs($);
sub genObsHeader ($$);
sub getObsInfo($);

#
# Main
#
my $result = 0;
$result = main();

exit($result);


###############################################################################
#
# package functions
# 

sub main() 
{
  $warn  = $cfg{"STATUS_DIR"}."/".$daemon_name.".warn";
  $error = $cfg{"STATUS_DIR"}."/".$daemon_name.".error";

  my $pid_file    = $cfg{"SERVER_CONTROL_DIR"}."/".$daemon_name.".pid";
  my $quit_file   = $cfg{"SERVER_CONTROL_DIR"}."/".$daemon_name.".quit";
  my $log_file    = $cfg{"SERVER_LOG_DIR"}."/".$daemon_name.".log";

  my $obs_results_dir  = $cfg{"SERVER_RESULTS_DIR"};
  my $control_thread   = 0;
  my @observations = ();
  my ($i, $obs_mode, $obs_config);
  my $o = "";
  my $t = "";
  my $num_headers = 0;
  my $result = "";
  my $response = "";
  my $counter = 5;
  my $cmd = "";

  # sanity check on whether the module is good to go
  ($result, $response) = good($quit_file);
  if ($result ne "ok") {
    print STDERR $response."\n";
    return 1;
  }

  # install signal handlers
  $SIG{INT} = \&sigHandle;
  $SIG{TERM} = \&sigHandle;
  $SIG{PIPE} = \&sigPipeHandle;

  # become a daemon
  Dada::daemonize($log_file, $pid_file);
  
  Dada::logMsg(0, $dl, "STARTING SCRIPT");

  ## set the 
  umask 022;
  my $umask_val = umask;

  # start the control thread
  Dada::logMsg(2, $dl, "main: controlThread(".$quit_file.", ".$pid_file.")");
  $control_thread = threads->new(\&controlThread, $quit_file, $pid_file);

  chdir $obs_results_dir;

  while (!$quit_daemon)
  {
    # TODO check that directories are correctly sorted by UTC_START time
    Dada::logMsg(2, $dl, "main: looking for obs.processing in ".$obs_results_dir);

    # Only get observations that are marked as procesing
    $cmd = "find ".$obs_results_dir." -mindepth 2 -maxdepth 2 -name 'obs.processing' ".
           "-printf '\%h\\n' | awk -F/ '{print \$NF}' | sort -n";

    Dada::logMsg(3, $dl, "main: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "main: ".$result." ".$response);

    if ($result eq "ok") 
    {
      @observations = split(/\n/,$response);

      # For process all valid observations
      for ($i=0; (($i<=$#observations) && (!$quit_daemon)); $i++)
      {
        $o = $observations[$i];

        my %obs_infos = getObsInfo($o);
        my $source;

        # determine the age of the observation
        Dada::logMsg(2, $dl, "main: getObsAge(".$o.")");
        my $age = getObsAge($o);
        Dada::logMsg(2, $dl, "main: getObsAge() ".$age);

        foreach $source (keys %obs_infos)
        {
          my $obs_type = $obs_infos{$source};
          my $results_dir = $obs_results_dir."/".$o."/".$source;

          Dada::logMsg(2, $dl, "main: utc_start=".$o." source=".$source." type=".$obs_type);

          my $req = "NA";
          if (($obs_type eq "CORR") || ($obs_type eq "TB"))
          {
            $req = $bf_cfg{"NUM_BF"};
            $cmd = "find ".$results_dir." -mindepth 2 -maxdepth 2 -type f -name 'obs.header' | wc -l";
          }
          if (($obs_type eq "FB") || ($obs_type eq "MB"))
          {
            $req = $bp_cfg{"NUM_BP"};
            $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type f -name 'obs.header.BP??' | wc -l";
          }
          Dada::logMsg(3, $dl, "main: ".$cmd);
          ($result, $response) = Dada::mySystem($cmd);
          Dada::logMsg(3, $dl, "main: ".$result." ".$response);
          if ($result ne "ok")
          {
            Dada::logMsgWarn($warn, "could not count number of BF suddirs");
            sleep(1);
            next;
          }

          # check that all subdirs are present
          if ($response ne $req)
          {
            Dada::logMsg(2, $dl, "main: utc_start=".$o." source=".$source." type=".$obs_type." ".$response." of ".$req." existed");
            next;
          }

          if ($obs_type eq "CORR")
          {
            processCorrObservation ($o, $source, $bf_cfg{"NUM_BF"});
          }
          if ($obs_type eq "TB")
          {
            processTbObservation($o, $source, $bf_cfg{"NUM_BF"}); 
          }
          if (($obs_type eq "FB") || ($obs_type eq "MB"))
          {
            processFbObservation($o, $source, $bp_cfg{"NUM_BP"}); 
          }
        }

        # if the osbervation is more than 40s old, mark it as finished
        if ($age > 120)
        {
          markObsState($o, "processing", "finished");
        }
        elsif ($age < -120)
        {
          markObsState($o, "processing", "failed");
        }
        else
        {
          Dada::logMsg(2, $dl, "main: normal processing age=".$age);
        }
      }
    }

    # if no obs.processing, check again in 5 seconds
    if ($#observations == -1) {
      $counter = 5;
    } else {
      $counter = 2;
    }
   
    while ($counter && !$quit_daemon)
    {
      sleep(1);
      $counter--;
    }
  }

  Dada::logMsg(2, $dl, "main: joining controlThread");
  $control_thread->join();

  Dada::logMsg(0, $dl, "STOPPING SCRIPT");

                                                                                
  return 0;
}

sub getObsInfo($)
{
  (my $obs) = @_;
  Dada::logMsg(2, $dl, "getObsInfo(".$obs.")");

  my $obs_info_file = $cfg{"SERVER_RESULTS_DIR"}."/".$obs."/obs.info";
  my %sources = ();
  my $i;

  if (-f $obs_info_file)
  {
    Dada::logMsg(2, $dl, "getObsInfo: ". $obs_info_file." existed");  
    my %obs_info = Dada::readCFGFileIntoHash ($obs_info_file, 0);

    if ((exists $obs_info{"CORR_ENABLED"}) && ($obs_info{"CORR_ENABLED"} eq "true"))
    {
      my $source = $obs_info{"SOURCE"};
      if (-d $cfg{"SERVER_RESULTS_DIR"}."/".$obs."/".$source)
      {
        $sources{$obs_info{"SOURCE"}} = "CORR";
      }
      else
      {
        Dada::logMsg(2, $dl, $source." did not exist in ".$obs);
      } 
    }

    for ($i=0; $i<$bf_cfg{"NUM_TIED_BEAMS"}; $i++)
    {
      if ((exists $obs_info{"TB".$i."_ENABLED"}) && ($obs_info{"TB".$i."_ENABLED"} eq "true"))
      {
        my $source = $obs_info{"TB".$i."_SOURCE"};
        if (-d $cfg{"SERVER_RESULTS_DIR"}."/".$obs."/".$source)
        {
          $sources{$obs_info{"TB".$i."_SOURCE"}} = "TB";
        }
        else
        {
          Dada::logMsg(2, $dl, $source." did not exist in ".$obs);
        } 
      }
    }

    if ((exists $obs_info{"FB_ENABLED"}) && ($obs_info{"FB_ENABLED"} eq "true"))
    {
      my $source = "FB";
      if (-d $cfg{"SERVER_RESULTS_DIR"}."/".$obs."/".$source)
      {
        $sources{"FB"} = "FB";
      }
      else
      {
        Dada::logMsg(2, $dl, $source." did not exist in ".$obs);
      }
    }

    if ((exists $obs_info{"MB_ENABLED"}) && ($obs_info{"MB_ENABLED"} eq "true"))
    {
      my $source = "FB";
      if (-d $cfg{"SERVER_RESULTS_DIR"}."/".$obs."/".$source)
      {
        $sources{"FB"} = "MB";
      }
      else
      {
        Dada::logMsg(2, $dl, $source." did not exist in ".$obs);
      }
    }
  }
  else
  {
    Dada::logMsg(2, $dl, "getObsInfo: ". $obs_info_file." did not exist");
  }
  return %sources;
}

###############################################################################
#
# Returns the "age" of the observation. Return value is the age in seconds of 
# the file of type $ext in the obs dir $o. If no files exist in the dir, then
# return the age of the newest dir in negative seconds
# 
sub getObsAge($)
{
  my ($o) = @_;
  Dada::logMsg(3, $dl, "getObsAge(".$o.")");

  my ($cmd, $result, $response);
  my $age = 0;
  my $time = 0;

  # current time in "unix seconds"
  my $now = time;

  $cmd = "find ".$o." -type f -name '*.ar' -printf '\%T@\\n' ".
                          "-o -name '*.tot' -printf '\%T@\\n' ".
                          "-o -name '*.cc' -printf '\%T@\\n' ".
                          "-o -name '*.sum' -printf '\%T@\\n' ".
                          "-o -name '*.cand' -printf '\%T@\\n' ".
                          "-o -name 'obs.header*' -printf '\%T@\\n' ".
                          "-o -name 'all_candidates.dat' -printf '\%T@\\n' ".
                          "| sort -n | tail -n 1";
  Dada::logMsg(3, $dl, "getObsAge: ".$cmd);
  ($result, $time) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "getObsAge: ".$result." ".$time);
  if ($time eq "")
  {
    $cmd = "find ".$o." -maxdepth 0 -type d -printf '\%T@\\n'";
        Dada::logMsg(3, $dl, "getObsAge: ".$cmd); 
    ($result, $time ) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "getObsAge: ".$result." ".$time);
    $age = $time - $now;
  }
  else
  {
    $age = $now - $time;
  }

  Dada::logMsg(2, $dl, "getObsAge: time=".$time.", now=".$now.", age=".$age);

  return $age;
}

###############################################################################
#
# Marks an observation as finished
# 
sub markObsState($$$) 
{
  my ($o, $old, $new) = @_;

  Dada::logMsg(2, $dl, "markObsState(".$o.", ".$old.", ".$new.")");

  my $cmd = "";
  my $result = "";
  my $response = "";
  my $archives_dir = $cfg{"SERVER_ARCHIVE_DIR"};
  my $results_dir  = $cfg{"SERVER_RESULTS_DIR"};
  my $state_change = $old." -> ".$new;
  my $old_file = "obs.".$old;
  my $new_file = "obs.".$new;
  my $file = "";
  my $ndel = 0;

  Dada::logMsg(1, $dl, $o." ".$old." -> ".$new);

  $cmd = "touch ".$results_dir."/".$o."/".$new_file;
  Dada::logMsg(2, $dl, "markObsState: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(2, $dl, "markObsState: ".$result." ".$response);

  $file = $results_dir."/".$o."/".$old_file;
  if ( -f $file ) {
    $ndel = unlink ($file);
    if ($ndel != 1) {
      Dada::logMsgWarn($warn, "markObsState: could not unlink ".$file);
    }
  } else {
    Dada::logMsgWarn($warn, "markObsState: expected file missing: ".$file);
  }
}


###############################################################################
# 
# Clean up the results directory for the observation
#
sub cleanResultsDir($) 
{
  (my $o) = @_;

  my $results_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$o;
  my ($ant, $source, $first_obs_header);
  my ($cmd, $result, $response);
  my @sources = ();
  my @ants = ();

  $cmd = "rm -f ".$results_dir."/*/*_pwc.finished";
  Dada::logMsg(2, $dl, "cleanResultsDir: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "cleanResultsDir: ".$result." ".$response);
  if ($result ne "ok"){
    Dada::logMsgWarn($warn, "cleanResultsDir: ".$cmd." failed: ".$response);
    return ("fail", "Could not remove delete [PWC]_pwc.finished files");
  }

  # get a list of the ants for this obs
  $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type d -printf '%f\n'";
  Dada::logMsg(2, $dl, "cleanResultsDir: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "cleanResultsDir: ".$result." ".$response);
  if ($result ne "ok") {
    Dada::logMsgWarn($warn, "cleanResultsDir: ".$cmd." failed: ".$response);
    return ("fail", "Could not get a list of ants");
  }
  @ants = split(/\n/, $response);

  # get a list of the sources for this obs
  $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type f -name '*_f.tot' -printf '\%f\\n' | awk -F_ '{print \$1}'";
  Dada::logMsg(2, $dl, "cleanResultsDir: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "cleanResultsDir: ".$result." ".$response);
  if ($result ne "ok") {
    Dada::logMsgWarn($warn, "cleanResultsDir: ".$cmd." failed: ".$response);
    return ("fail", "Could not remove get a list of the sources");
  }
  @sources = split(/\n/, $response);

  # delete the .tim files use for pulsar timing plots
  $cmd = "find ".$results_dir." -name '*.tim' -delete";
  Dada::logMsg(2, $dl, "cleanResultsDir: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "cleanResultsDir: ".$result." ".$response);
  if ($result ne "ok") {
    Dada::logMsgWarn($warn, "cleanResultsDir: ".$cmd." failed: ".$response);
    return ("fail", "Could not remove remove old .tim files");
  }

  Dada::logMsg(2, $dl, "cleanResultsDir: deleting old pngs");
  removeOldPngs($o);
}


##############################################################################
#
# Process the obs.header.BP files for this observation, candidate processing
# is performed in server_mopsr_frb_manager.pl
#
sub processFbObservation($$$) 
{
  my ($o, $s, $num_bp) = @_;
  Dada::logMsg(2, $dl, "processFbObservation(".$o.", ".$s.", ".$num_bp.")");

  my ($cmd, $result, $response, $key);

  my $results_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$o."/".$s;
  my $archive_dir = $cfg{"SERVER_ARCHIVE_DIR"}."/".$o."/".$s;
  my $obs_header_file = $results_dir."/obs.header";

  if (!(-d $archive_dir))
  {
    ($result, $response) = Dada::mkdirRecursive ($archive_dir, 0755);
    if ($result ne "ok")
    {
      Dada::logMsg(0, $dl, "processFbObservation: mkdirRecursive(".$archive_dir.") failed: ".$response);
      return ("fail", "could not create archive_dir");
    }
  }

  if (!( -f $obs_header_file))
  {
    $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type f -name 'obs.header.BP??' | head -n 1";
    Dada::logMsg(2, $dl, "processFbObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "processFbObservation: ".$result." ".$response);
    if (($result ne "ok") || ($response eq ""))
    {
      Dada::logMsg(0, $dl, "processFbObservation: ".$cmd." failed: ".$response);
      return ("fail", "could not find a obs.header file");
    }

    my %h = Dada::readCFGFileIntoHash ($response, 0);

    # now determine the total number of beams
    $cmd = "grep ^NBEAM ".$results_dir."/obs.header.BP?? | awk '{sum += \$2} END {print sum}'";
    Dada::logMsg(2, $dl, "processFbObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "processFbObservation: ".$result." ".$response);
    if (($result ne "ok") || ($response eq ""))
    {
      Dada::logMsg(0, $dl, "processFbObservation: ".$cmd." failed: ".$response);
      return ("fail", "could not extract nbeams");
    }
    my $new_nbeam = $response;

    #$cmd = "grep ^BEAM_MD_OFFSETS ".$results_dir."/obs.header.BP?? | awk '{print \$2}'";
    #Dada::logMsg(2, $dl, "processFbObservation: ".$cmd);
    #($result, $response) = Dada::mySystem($cmd);
    #Dada::logMsg(3, $dl, "processFbObservation: ".$result." ".$response);
    #if (($result ne "ok") || ($response eq ""))
    #{
    #  Dada::logMsg(0, $dl, "processFbObservation: ".$cmd." failed: ".$response);
    #  return ("fail", "could not extract BEAM_MD_OFFSETS");
    #}
    #my $new_md_offsets = $response;
    #$new_md_offsets =~ s/\n/,/g;

    # overwrite the old values with new ones
    #$h{"BEAM_MD_OFFSETS"} = $new_md_offsets;
    $h{"NBEAM"} = $new_nbeam;

    open FH, ">".$obs_header_file or return ("fail", "Could not write to ".$obs_header_file);
    print FH "# obs.header created by ".$0."\n";
    print FH "# Created: ".Dada::getCurrentDadaTime()."\n\n";
    foreach $key ( keys %h )
    {
      # ignore some irrelvant keys
      print FH Dada::headerFormat($key, $h{$key})."\n";
    }
    close FH;

    $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type f -name 'obs.header.BP??'";
    Dada::logMsg(2, $dl, "processFbObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "processFbObservation: ".$result." ".$response);
    if (($result ne "ok") || ($response eq ""))
    {
      Dada::logMsg(0, $dl, "processFbObservation: ".$cmd." failed: ".$response);
      return ("fail", "could not delete obs.header.BP??");
    }

    $cmd = "cp ".$obs_header_file." ".$archive_dir."/";
    Dada::logMsg(2, $dl, "processTbObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    if ($result ne "ok")
    {
      Dada::logMsg(0, $dl, "processFbObservation: ".$cmd." failed: ".$response);
      return ("fail", "failed to copy obs.header to archive_dir");
    }
    return ("ok", $obs_header_file);
  }
  return ("ok", "");
}

##############################################################################
#
# Process all possible archives in the observation, combining the bands
# and plotting the most recent images. Accounts for multifold  PSRS
#
sub processTbObservation($$$) 
{
  my ($o, $s, $num_bf) = @_;
  Dada::logMsg(2, $dl, "processTbObservation(".$o.", ".$s.", ".$num_bf.")");

  my $i = 0;
  my $k = "";
  my ($fres_ar, $tres_ar, $latest_archive);
  my ($source, $archive, $file, $chan, $count, $nchan);
  my ($cmd, $result, $response);
  my @files = ();
  my %archives = ();

  my $results_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$o."/".$s;
  my $archive_dir = $cfg{"SERVER_ARCHIVE_DIR"}."/".$o."/".$s;
  my $obs_header_file = $results_dir."/obs.header";

  if (!-f $obs_header_file) 
  {
    ($result, $response) = genObsHeader ($results_dir, $num_bf);
    if ($result ne "ok")
    {
      Dada::logMsgWarn($warn, "processTbObservation: failed to generate obs.header");
      return ("fail", "failed to generate obs.header");
    }
    
    $cmd = "cp ".$obs_header_file." ".$archive_dir."/";
    Dada::logMsg(2, $dl, "processTbObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    if ($result ne "ok")
    {
      return ("fail", "failed to copy obs.header to archive_dir");
    }
  }

  my %h = Dada::readCFGFileIntoHash ($obs_header_file, 0);
  
  # get the source for this TB observation
  $source = $h{"SOURCE"};
  $nchan  = $h{"NCHAN"};

  # get a list of BF subdirs
  $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type d -name 'BF??' -printf '%f\n' | sort -n";
  Dada::logMsg(3, $dl, "processTbObservation: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "processTbObservation: ".$result." ".$response);
  if ($result ne "ok") 
  {
    Dada::logMsgWarn($warn, "processTbObservation: ".$cmd." failed: ".$response);
    return;
  }

  my @bf_dirs = split(/\n/, $response);

  # get a list of the unprocessing archives in each channel
  $cmd = "find ".$results_dir." -mindepth 2 -maxdepth 2 -type f -name '????-??-??-??:??:??.ar'".
         " -printf '%h/%f\n' -o -name 'pulse_*.ar' -printf '%h/%f\n' | sort -n";
  Dada::logMsg(2, $dl, "processTbObservation: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "processTbObservation: ".$result." ".$response);
  if ($result ne "ok")
  {
    Dada::logMsgWarn($warn, "processTbObservation: ".$cmd." failed: ".$response);
    return;
  }
  if ($response eq "")
  {
    Dada::logMsg(2, $dl, "processTbObservation: did not find any archives for ".$o);
    return;
  }

  # count the number of archives for each channel
  @files = split(/\n/, $response);
  Dada::logMsg(2, $dl, "processTbObservation: found ".($#files + 1)." channel archives");
  %archives = ();
  foreach $file (@files)
  {
    my @parts = split(/\//, $file);
    my $n = $#parts;

    $chan    = $parts[$n-1];
    $archive = $parts[$n];

    if (!exists($archives{$archive}))
    {
      $archives{$archive} = 0;
    }
    $archives{$archive}++;
  }

  $fres_ar = "";
  $tres_ar = "";

  foreach $archive ( sort keys %archives )
  {
    $count = $archives{$archive};
    Dada::logMsg(2, $dl, "processTbObservation: found ".$count." channel archives");

    if ($count == $num_bf)
    {
      Dada::logMsg(2, $dl, "processTbObservation: appendArchive(".$o.", ".$source.", ".$archive.")");
      ($result, $fres_ar, $tres_ar) = appendArchive($o, $source, $archive);
      Dada::logMsg(3, $dl, "processTbObservation: appendArchives() ".$result);

      if (($result eq "ok") && ($fres_ar ne "") && ($tres_ar ne ""))
      {
        $cmd = "find ".$cfg{"SERVER_ARCHIVE_DIR"}."/".$o."/".$s." -name '2???-??-??-??:??:??.ar' ".
               "-o -name 'pulse_*.ar' | sort -n | tail -n 1";
        Dada::logMsg(2, $dl, "processTbObservation: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(2, $dl, "processTbObservation: ".$result." ".$response);
        if ($result eq "ok") {
          $latest_archive = $response;
        } else {
          $latest_archive = "";
        }
      }
    }
  }

  if ($fres_ar ne "")
  {
    Dada::logMsg(2, $dl, "processTbObservation: plotting [".$i."] (".$o.", ".$source.", ".$fres_ar.", ".$tres_ar.")");
    makePlotsFromArchives($o, $fres_ar, $tres_ar, "120x90", $latest_archive, $source);
    makePlotsFromArchives($o, $fres_ar, $tres_ar, "1024x768", $latest_archive, $source);
    removeOldPngs($o);
  }
}

###############################################################################
#
# FADD the archives together and append to FRES and TRES totals
#
sub appendArchive($$$) 
{
  my ($utc_start, $source, $archive) = @_;

  Dada::logMsg(2, $dl, "appendArchive(".$utc_start.", ".$source.", ".$archive.")");

  my $results_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$utc_start."/".$source;
  my $archive_dir = $cfg{"SERVER_ARCHIVE_DIR"}."/".$utc_start."/".$source;

  my $total_t_sum = $results_dir."/".$archive;
  my $source_f_res = $results_dir."/".$source."_f.tot";
  my $source_t_res = $results_dir."/".$source."_t.tot";
  my $power_mon_log = $results_dir."/power_monitor.log";

  my $cmd = "";
  my $result = "";
  my $response = "";
  my $new_pm_text = "";
  my @powers = ();
  my $power = "";

  my $nchan_coarse = (int($cfg{"PWC_END_CHAN"}) - int($cfg{"PWC_START_CHAN"})) + 1;
  Dada::logMsg(2, $dl, "appendArchive: nchan=".$nchan_coarse." END=".$cfg{"PWC_END_CHAN"}." START=".$cfg{"PWC_START_CHAN"});
  my $psh;
  if ($nchan_coarse <= 8)
  {
    $psh = $cfg{"SCRIPTS_DIR"}."/power_mon8.psh";
  }
  elsif ($nchan_coarse == 20)
  {
    $psh = $cfg{"SCRIPTS_DIR"}."/power_mon20.psh";
  }
  else
  {
    $psh = $cfg{"SCRIPTS_DIR"}."/power_mon.psh";
  }

  # If the server's archive dir for this observation doesn't exist with the source
  ($result, $response) = Dada::mkdirRecursive ($archive_dir, 0755);

  # add the individual archives together into a single archive with frequency resolution
  $cmd = "psradd -R -o ".$total_t_sum." ".$results_dir."/BF??/".$archive;
  Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
  if ($result ne "ok") 
  {
    Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
    return ("fail", "", "");
  }
    
  if (! -f $total_t_sum) 
  {
    Dada::logMsg(0, $dl, "appendArchive: archive [".$total_t_sum."] did not exist");
    return ("fail", "", "");
  }

  # now delete in the individual channel archives
  $cmd = "rm -f ".$results_dir."/BF??/".$archive;
  Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
  if ($result ne "ok")
  {
    Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
    return ("fail", "", "");
  }


  # save this archive to the server's archive dir for permanent archival
  $cmd = "cp --preserve=all ".$total_t_sum." ".$archive_dir."/";
  Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
  if ($result ne "ok") {
    Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
    return ("fail", "", "");
  }

  $new_pm_text = "";
  # The total power monitor needs first line as int:freq
  if ( ! -f $power_mon_log )
  {
    $cmd = "psrstat -J ".$psh." -Q -c 'int:freq' ".$total_t_sum." | awk '{print \$2}' | awk -F, '{ printf (\"UTC\"); for(i=1;i<=NF;i++) printf (\",\%4.0f\",\$i); printf(\"\\n\") }'";
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result eq "ok")
    {
      $new_pm_text = $response."\n";
    }
  }

  if (!($archive =~ m/^pulse/))
  {
    $cmd = "psrstat -J ".$psh." -Q -q -l chan=0- -c all:sum ".$total_t_sum." | awk '{printf(\"%6.3f\\n\",\$1)}'";
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result eq "ok")
    {
      @powers = split(/\n/,$response);

      $archive =~ s/\.ar$//;
      my $archive_time_unix = Dada::getUnixTimeUTC($archive);
      my $utc_time_unix = Dada::getUnixTimeUTC($utc_start);
      my $offset = $archive_time_unix - $utc_time_unix;

      $new_pm_text .= $offset;
      foreach $power ( @powers )
      {
        $new_pm_text .= ",".$power;
      }
      $new_pm_text .= "\n";

      open FH, ">>".$power_mon_log;
      print FH $new_pm_text;
      close FH;
    }
  }

  # If this is the first result for this observation
  if (!(-f $source_f_res)) 
  {
    # "create" the source's fres archive
    $cmd = "cp ".$total_t_sum." ".$source_f_res;
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result ne "ok") { 
      Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
      return ("fail", "", "");
    }

    # Fscrunc the archive
    $cmd = "pam -F -m ".$total_t_sum;
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result ne "ok") { 
      Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
      return ("fail", "", "");
    }

    # Now we have the tres archive
    $cmd = "cp ".$total_t_sum." ".$source_t_res;
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result ne "ok") { 
      Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
      return ("fail", "", "");
    }
  
  # we are appending to the sources f and t res archives
  } else {

    # Add the new archive to the FRES total [tsrunching it]
    $cmd = "psradd -T -o ".$source_f_res." ".$source_f_res." ".$total_t_sum;
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result ne "ok") { 
      Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
      return ("fail", "", "");
    }

    # Fscrunc the archive for adding to the TRES
    $cmd = "pam -F -m ".$total_t_sum;
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result ne "ok") { 
      Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
      return ("fail", "", "");
    }

    # Add the Fscrunched archive to the TRES total 
    $cmd = "psradd -o ".$source_t_res." ".$source_t_res." ".$total_t_sum;
    Dada::logMsg(2, $dl, "appendArchive: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "appendArchive: ".$result." ".$response);
    if ($result ne "ok") {
      Dada::logMsg(0, $dl, "appendArchive: ".$cmd." failed: ".$response);
      return ("fail", "", "");
    }

    Dada::logMsg(2, $dl, "appendArchive: done");
  }

  # clean up the current archive
  unlink($total_t_sum);
  Dada::logMsg(2, $dl, "appendArchive: unlinking ".$total_t_sum);

  return ("ok", $source_f_res, $source_t_res);
}

###############################################################################
#
# Create plots for use in the web interface
#
sub makePlotsFromArchives($$$$$$) 
{
  my ($dir, $total_f_res, $total_t_res, $res, $ten_sec_archive, $source) = @_;

  my $web_style_txt = $cfg{"SCRIPTS_DIR"}."/web_style.txt";
  my $args = "-g ".$res." ";
  my $pm_args = "-g ".$res." -m ".$source." ";
  my ($cmd, $result, $response);
  my ($bscrunch, $bscrunch_t);
  my $sdir = $dir."/".$source;

  my $nchan = (int($cfg{"PWC_END_CHAN"}) - int($cfg{"PWC_START_CHAN"})) + 1;
  if ($nchan == 20)
  {
    $nchan = 4;
  }
  if ($nchan == 40)
  {
    $nchan = 8;
  }
  if ($nchan == 320)
  {
    $nchan = 8;
  }

  # If we are plotting hi-res - include
  if ($res ne "1024x768") 
  {
    $args .= " -s ".$web_style_txt." -c below:l=unset";
    $bscrunch = " -j 'B 128'";
    $bscrunch_t = " -j 'B 128'";
    $pm_args .= " -p";
  } else {
    $bscrunch = "";
    $bscrunch_t = "";
  }

  my $bin = Dada::getCurrentBinaryVersion()."/psrplot ".$args;
  my $timestamp = Dada::getCurrentDadaTime(0);

  my $ti = $timestamp.".".$source.".ti.".$res.".png";
  my $fr = $timestamp.".".$source.".fr.".$res.".png";
  my $fl = $timestamp.".".$source.".fl.".$res.".png";
  my $bp = $timestamp.".".$source.".bp.".$res.".png";
  my $pm = $timestamp.".".$source.".pm.".$res.".png";
  my $ta = $timestamp.".".$source.".ta.".$res.".png";
  my $tc = $timestamp.".".$source.".tc.".$res.".png";
  my $l9 = $timestamp.".".$source.".l9.".$res.".png";
  my $st = $timestamp.".".$source.".st.".$res.".png";

  # Combine the archives from the machine into the archive to be processed
  # PHASE vs TIME
  $cmd = $bin.$bscrunch_t." -p time -jFD -D ".$dir."/pvt_tmp/png ".$total_t_res;
  Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

  # PHASE vs FREQ
  $cmd = $bin.$bscrunch." -p freq -jTD -D ".$dir."/pvfr_tmp/png ".$total_f_res;
  Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

  # PHASE vs TOTAL INTENSITY
  $cmd = $bin.$bscrunch." -p flux -jTFD -D ".$dir."/pvfl_tmp/png ".$total_f_res;
  Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

  # BANDPASS
  $cmd = $bin." -pb -x -D ".$dir."/bp_tmp/png ".$ten_sec_archive;
  Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

  # TOAS
  my $timing_repo_topdir = "/home/observer/Timing/";
  my $template_pattern = $timing_repo_topdir."ephemerides/".$source."/*.std";
  my @template = glob($template_pattern);
  my $ephem_pattern = $timing_repo_topdir."ephemerides/".$source."/good.par";
  my @ephem = glob($ephem_pattern);
  if (@template and @ephem) {
    if ( ! ( -f $sdir."/previous.tim" ) ) {
      $cmd = "pat -j FT -s ".$template[0]." -A FDM -f tempo2 /home/observer/Timing/profiles/".$source."/*FT > ".$sdir."/previous.tim";
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::myShellStdout($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
    }

    $cmd = "cp ".$sdir."/previous.tim ".$sdir."/temp.tim";
    Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
    ($result, $response) = Dada::myShellStdout($cmd);
    Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
    if ($result eq "ok") {
      # add the current ToA, mark as last, filter 0 uncertainty
      $cmd = "pat -j FT -s ".$template[0]." -A FDM -f tempo2 ".$total_t_res." | grep -v ^FORMAT | sed 's/\$/-last yes/' | awk '{if (NF==2 || \$4>0) {print \$0} else print \"C \"\$0}' >> ".$sdir."/temp.tim";
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::myShellStdout($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      if ($result eq "ok") {
        $cmd = "tempo2 -gr plk -set FINISH 99999 -setup ".$ENV{"TEMPO2"}."/plugin_data/plk_setup_image_molo.dat -f ".$ephem[0]." ".$sdir."/temp.tim -nofit -xplot 10 -showchisq -grdev ".$dir."/".$ta."/png";
        Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

        $cmd = "remove-outliers2 -c ".$sdir."/outlier_sweep1 -s 0.3 -m smooth -p ".$ephem[0]." -t ".$sdir."/temp.tim > ".$sdir."/temp.clean_smooth.tim";
        Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
        $cmd = "remove-outliers2 -c ".$sdir."/outlier_sweep2 -m mad -p ".$ephem[0]." -t ".$sdir."/temp.clean_smooth.tim > ".$sdir."/temp.clean.tim";
        Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

        # ensure last point survives
        $cmd = "cat ".$sdir."/temp.clean.tim | grep -v last > ".$sdir."/temp.clean.tim2 ; cat ".$sdir."/temp.clean.tim | grep last | sed 's/^C//' >> ".$sdir."/temp.clean.tim2; mv ".$sdir."/temp.clean.tim2 ".$sdir."/temp.clean.tim";
        Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

        if ($result eq "ok") {
          # check if anything survived the cleaning:
          $cmd ="grep -v -e ^C -e ^FORMAT ".$sdir."/temp.clean.tim | wc -l";
          Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
          ($result, $response) = Dada::mySystem($cmd);
          Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

          if ($response gt 0) {
            $cmd = "tempo2 -gr plk -set FINISH 99999 -setup ".$ENV{"TEMPO2"}."/plugin_data/plk_setup_image_molo.dat -f ".$ephem[0]." ".$sdir."/temp.clean.tim -nofit -xplot 10 -showchisq -grdev ".$dir."/".$tc."/png";
            Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
            ($result, $response) = Dada::mySystem($cmd);
            Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
          } else {
            $cmd = "cp ".$dir."/".$ta." ".$dir."/".$tc;
            Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
            ($result, $response) = Dada::mySystem($cmd);
            Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
          }
        }
      }
    }
  } else {
    # Don't have a template and/or ephemeris:
    # Images generated with:
    # convert -size 1024x768 -gravity center -background white -fill "#FF00B8" label:"No template" no_template_1024x768.png
    # convert -size 120x90 -gravity center -background white -fill "#FF00B8" label:"No template" no_template_120x90.png
    # convert -size 1024x768 -gravity center -background white -fill "#FF00B8" label:"No ephemeris" no_ephemeris_1024x768.png
    # convert -size 120x90 -gravity center -background white -fill "#FF00B8" label:"No ephemeris" no_ephemeris_120x90.png
    # convert -size 1024x768 -gravity center -background white -fill "#FF00B8" label:"No template\nNo ephemeris" no_template_ephemeris_1024x768.png
    # convert -size 120x90 -gravity center -background white -fill "#FF00B8" label:"No template\nNo ephemeris" no_template_ephemeris_120x90.png
    if (not @template and not @ephem) {
      $cmd = "cp ".$dir."/../no_template_ephemeris_".$res.".png ".$dir."/".$tc;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      $cmd = "cp ".$dir."/../no_template_ephemeris_".$res.".png ".$dir."/".$ta;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
    } elsif (not @template) {
      $cmd = "cp ".$dir."/../no_template_".$res.".png ".$dir."/".$tc;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      $cmd = "cp ".$dir."/../no_template_".$res.".png ".$dir."/".$ta;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      $cmd = "cp ".$dir."/../no_template_".$res.".png ".$dir."/".$st;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
    } elsif (not @ephem) {
      $cmd = "cp ".$dir."/../no_ephemeris_".$res.".png ".$dir."/".$tc;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      $cmd = "cp ".$dir."/../no_ephemeris_".$res.".png ".$dir."/".$ta;
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
    }
  }

  # POWER MONITOR
  if (-f $sdir."/power_monitor.log")
  {
    $cmd = "mopsr_pmplot -c ".$nchan." ".$pm_args." -D ".$dir."/pm_tmp/png ".$sdir."/power_monitor.log";
    Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
  }

  # plot the last 9 image
  $cmd = "find ".$dir." -name '*.".$source.".l9.".$res.".png' | wc -l";
  Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
  if (($result eq "ok") && ($response eq "0"))
  {
    my $ft_dir = "/home/observer/Timing/profiles/".$source;
    if ( -d $ft_dir )
    {
      $cmd = "find ".$ft_dir." -name '*.FT' | sort  | tail -n 9";
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

      if ($result eq "ok" && $response ne "")
      {
        $response =~ s/\n/ /g;
        $cmd = "psrplot -jFT -pD -N3,3 -jC ".$args." -D ".$dir."/".$l9."/png ".$response;
        Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      }
    }
  }

  # plot the standard 
  $cmd = "find ".$dir." -name '*.".$source.".st.".$res.".png' | wc -l";
  Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
  if (($result eq "ok") && ($response eq "0"))
  {
    my $par_dir = "/home/observer/Timing/ephemerides/".$source;
    if ( -d $par_dir )
    {
      $cmd = "find ".$par_dir." -name '*.std' | tail -n 1";
      Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);

      if ($result eq "ok" && $response ne "")
      {
        $response =~ s/\n/ /;
        $cmd = "psrplot -p flux -jC ".$args." -D ".$dir."/".$st."/png ".$response;
        Dada::logMsg(2, $dl, "makePlotsFromArchives: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        Dada::logMsg(3, $dl, "makePlotsFromArchives: ".$result." ".$response);
      }
    }
  }

  # wait for each file to "appear"
  my $waitMax = 5;
  while ($waitMax) {
    if ( (-f $dir."/pvfl_tmp") &&
         (-f $dir."/pvt_tmp") &&
         (-f $dir."/pvfr_tmp") &&
         (-f $dir."/bp_tmp") &&
         ( (! -f $sdir."/power_monitor.log") || (-f $dir."/pm_tmp") ) )
    {
      $waitMax = 0;
    } else {
      $waitMax--;
      usleep(500000);
    }
  }

  # rename the plot files to their correct names
  system("mv -f ".$dir."/pvt_tmp ".$dir."/".$ti);
  system("mv -f ".$dir."/pvfr_tmp ".$dir."/".$fr);
  system("mv -f ".$dir."/pvfl_tmp ".$dir."/".$fl);
  system("mv -f ".$dir."/bp_tmp ".$dir."/".$bp);
  if ((-f $sdir."/power_monitor.log") && (-f $dir."/pm_tmp" ))
  {
    system("mv -f ".$dir."/pm_tmp ".$dir."/".$pm);
  }
  Dada::logMsg(2, $dl, "makePlotsFromArchives: plots renamed");
}


###############################################################################
#
# remove old pngs
#
sub removeOldPngs($)
{
  my ($dir) = @_;

  my ($cmd, $img_string, $i, $now);
  my ($time, $ant, $type, $res, $ext, $time_unix);

  $cmd = "find ".$dir." -ignore_readdir_race -mindepth 1 -maxdepth 1 -name '2*.*.??.*x*.png' -printf '%f\n' | sort -n";
  Dada::logMsg(2, $dl, "removeOldPngs: ".$cmd);

  $img_string = `$cmd`;
  my @images = split(/\n/, $img_string);
  my %to_use = ();

  for ($i=0; $i<=$#images; $i++)
  {
    ($time, $ant, $type, $res, $ext) = split(/\./, $images[$i]);
    if (!exists($to_use{$ant}))
    {
      $to_use{$ant} = ();
    }
    $to_use{$ant}{$type.".".$res} = $images[$i];
  }

  $now = time;

  for ($i=0; $i<=$#images; $i++)
  {
    ($time, $ant, $type, $res, $ext) = split(/\./, $images[$i]);
    $time_unix = Dada::getUnixTimeLocal($time);

    # if this is not the most recent matching type + res
    if ($to_use{$ant}{$type.".".$res} ne $images[$i])
    {
      # only delete if > 30 seconds old
      if (($time_unix + 30) < $now)
      {
        Dada::logMsg(3, $dl, "removeOldPngs: deleteing ".$dir."/".$images[$i].", duplicate, age=".($now-$time_unix));
        unlink $dir."/".$images[$i];
      }
      else
      {
        Dada::logMsg(3, $dl, "removeOldPngs: keeping ".$dir."/".$images[$i].", duplicate, age=".($now-$time_unix));
      }
    }
    else
    {
      Dada::logMsg(3, $dl, "removeOldPngs: keeping ".$dir."/".$images[$i].", newest, age=".($now-$time_unix));
    }
  }
}

###############################################################################
#
# Generate obs.header file for a Tied Beam or Correlator observation [BF]
#
sub genObsHeader ($$)
{
  my ($dir, $num_bf) = @_;

  my ($cmd, $result, $response, $key);

  $cmd = "find ".$dir." -mindepth 2 -maxdepth 2 -type f -name 'obs.header' | head -n 1";
  Dada::logMsg(2, $dl, "genObsHeader: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "genObsHeader: ".$result." ".$response);
  if (($result ne "ok") || ($response eq ""))
  {
    Dada::logMsg(0, $dl, "genObsHeader: ".$cmd." failed: ".$response);
    return ("fail", "could not find a obs.header file");
  }

  my %h = Dada::readCFGFileIntoHash ($response, 0);

  # now determine the centre frequnecy
  $cmd = "grep ^FREQ ".$dir."/BF??/obs.header | awk '{print \$2}' | sort -n";
  Dada::logMsg(2, $dl, "genObsHeader: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "genObsHeader: ".$result." ".$response);
  if (($result ne "ok") || ($response eq ""))
  {
    Dada::logMsg(0, $dl, "genObsHeader: ".$cmd." failed: ".$response);
    return ("fail", "could not extract coarse channel freqs");
  }
  my @freqs = split(/\n/, $response);

  # determine the total number of channels
  $cmd = "grep ^NCHAN ".$dir."/BF??/obs.header | awk '{sum += \$2} END {print sum}'";
  Dada::logMsg(2, $dl, "genObsHeader: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "genObsHeader: ".$result." ".$response);
  if (($result ne "ok") || ($response eq ""))
  { 
    Dada::logMsg(0, $dl, "genObsHeader: ".$cmd." failed: ".$response);
    return ("fail", "could not extract total number of channels");
  }
  my $new_nchan = $response;

  $cmd = "grep ^BW ".$dir."/BF??/obs.header | awk '{sum += \$2} END {print sum}'";
  Dada::logMsg(2, $dl, "genObsHeader: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "genObsHeader: ".$result." ".$response);
  if (($result ne "ok") || ($response eq ""))
  {
    Dada::logMsg(0, $dl, "genObsHeader: ".$cmd." failed: ".$response);
    return ("fail", "could not extract total bandwidth");
  }
  my $new_bw = $response;

  my $freq_lo = $freqs[0];
  my $freq_hi = $freqs[$#freqs];
  my $new_freq = $freq_lo + (($freq_hi - $freq_lo) / 2);

  # overwrite the old values with new ones
  $h{"FREQ"}  = $new_freq;
  $h{"BW"}    = $new_bw;
  $h{"NCHAN"} = $new_nchan;
  $h{"ORDER"} = "SF";

  my $obs_header_file = $dir."/obs.header";
  open FH, ">".$obs_header_file or return ("fail", "Could not write to ".$obs_header_file);
  print FH "# Specification File created by ".$0."\n";
  print FH "# Created: ".Dada::getCurrentDadaTime()."\n\n";

  foreach $key ( keys %h )
  {
    # ignore some irrelvant keys
    if ($key ne "ANTENNAE")
    {
      print FH Dada::headerFormat($key, $h{$key})."\n";
    }
  }
  close FH;

  return ("ok", $obs_header_file);
}


###############################################################################
#
# Process a Correlation Observation
#
sub processCorrObservation($$$)
{
  my ($o, $s, $num_bf) = @_;
  Dada::logMsg(2, $dl, "processCorrObservation(".$o.", ".$s.", ".$num_bf.")");

  my $i = 0;
  my $k = "";
  my ($archive_dir, $results_dir, $nchan, $summed_file, $first_time);
  my ($cmd, $result, $response, $ichan, $file_list);
  my ($file, $junk, $chan_dir, $tsum, $plus, $ifile);
  my ($key, $nant, $bw);
  my @chans = ();
  my @archives = ();
  my @dumps = ();
  my @files = ();
  my %unprocessed = ();

  # ensure the archives dir exists
  $archive_dir = $cfg{"SERVER_ARCHIVE_DIR"}."/".$o."/".$s;
  $results_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$o."/".$s;
  $results_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$o."/".$s;

  ($result, $response) = Dada::mkdirRecursive($archive_dir, 0755);
  if ($result ne "ok")
  {
    Dada::logMsgWarn($warn, "processCorrObservation: could not create dir: ".$response);
    return ("fail", "could not create dir");
  }

  # get a list of all the BF subdirs
  $cmd = "find ".$results_dir." -mindepth 1 -maxdepth 1 -type d -name 'BF??' -printf '%f\n' | sort -n";
  Dada::logMsg(3, $dl, "processCorrObservation: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$response);
  if ($result ne "ok")
  {
    Dada::logMsgWarn($warn, "processCorrObservation: ".$cmd." failed: ".$response);
    return ("fail", "no CH directories existing yet");
  }

  my @bf_dirs = split(/\n/, $response);

  # ensure an obs.header file exists for this observation
  my $obs_header_file = $results_dir."/obs.header";
  if (!(-f $obs_header_file))
  {
    ($result, $response) = genObsHeader ($results_dir, $num_bf);
    if ($result ne "ok")
    {
      Dada::logMsgWarn($warn, "processCorrObservation: failed to generate obs.header");
      return ("fail", "failed to generate obs.header");
    }

    $cmd = "cp ".$obs_header_file." ".$archive_dir."/";
    Dada::logMsg(2, $dl, "processCorrObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    if ($result ne "ok")
    {
      return ("fail", "failed to copy obs.header to archive_dir");
    }
  }

  my %obs_header = Dada::readCFGFileIntoHash ($obs_header_file, 0);
  $nant = $obs_header{"NANT"};
  $nchan = $obs_header{"NCHAN"};
  $bw = $obs_header{"BW"};

  # get a list of the unprocessed correlator dumps
  $cmd = "find ".$results_dir." -mindepth 2 -maxdepth 2 -type f -name '*.?c' -printf '%f\n' | sort -n";
  Dada::logMsg(3, $dl, "processCorrObservation: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$response);
  if ($result ne "ok")
  {
    Dada::logMsgWarn($warn, "processCorrObservation: ".$cmd." failed: ".$response);
    return;
  }
  @files = split(/\n/, $response);

  foreach $file (@files) 
  {
    if (! exists($unprocessed{$file}))
    {
      $unprocessed{$file} = 0;
    }
    $unprocessed{$file} += 1;
  }

  @files = sort keys %unprocessed;
  my $n_appended = 0;
  
  my $coarse_nchan = -1;    # number of channels per BF?? file
  my $corr_nchan = -1;      # number of channels across whole band

  for ($ifile=0; $ifile<=$#files; $ifile++)
  {
    $file = $files[$ifile];
    $summed_file = 0;

    if ($coarse_nchan == -1)
    {
      $cmd = "find ".$results_dir." -mindepth 2 -maxdepth 2 -type f -name '".$file."'";
      Dada::logMsg(3, $dl, "processCorrObservation: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$response);
      $corr_nchan = 0;
      if (($result eq "ok") && ($response ne ""))
      { 
        my @cc_files = split(/\n/, $response);
        my $cc_file;
        foreach $cc_file ( @cc_files )
        {
          my @stat = stat $cc_file;
          my $filesize = $stat[7];
          my $nbaselines = ($nant * ($nant - 1)) / 2;
          if ($file =~ m/.cc$/)
          {
            $coarse_nchan = $filesize / ($nbaselines * 8);
          }
          else
          {
            $coarse_nchan = $filesize / ($nant * 4);
          }
          $corr_nchan += $coarse_nchan;
        }
      }
    }

    Dada::logMsg(2, $dl, "processCorrObservation: input_nchan=".$nchan." corr_nchan=".$corr_nchan);

    if ($unprocessed{$file} == $num_bf)
    {
      Dada::logMsg(2, $dl, "processCorrObservation: appendCorrFile(".$file.", ".$nant.")");
      ($result, $response) = appendCorrFile($results_dir, $file, $nant);
      if ($result ne "ok")
      {
        Dada::logMsgWarn($warn, "processCorrObservation: failed to Fappend file [".$file."]: ".$response);
        return ("fail", "could not Fappend file");;
      }
      $n_appended++;
      $summed_file = $results_dir."/".$response;

      $tsum = $results_dir."/ac.sum";
      $plus = "-a";

      if ($file =~ m/\.cc/)
      {
        $tsum = $results_dir."/cc.sum";
        $plus = "-c";
      }

      # now add this file to the Tscrunched total
      $cmd = "mopsr_corr_sum ".$plus." ".$tsum." ".$plus." ".$summed_file." ".$tsum;

      if (!(-f $tsum))
      {
        $cmd = "cp ".$summed_file." ".$tsum;
      }

      Dada::logMsg(2, $dl, "processCorrObservation: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$response);
      if ($result ne "ok")
      {
        Dada::logMsgWarn($warn, "processCorrObservation: failed to Tappend file [".$file."]: ".$response);
        return ("fail", "could not Tappend file");
      }

      # finally moved this file to the archives directory
      $cmd = "mv ".$summed_file." ".$archive_dir."/";
      Dada::logMsg(2, $dl, "processCorrObservation: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$response);
      if ($result ne "ok")
      {
        Dada::logMsgWarn($warn, "processCorrObservation: failed to move file [".$file."] to archive_dir: ".$response);
        return ("fail", "could not Tappend file");
      }

    }
  }

  if (($n_appended > 0) && (-f $results_dir."/cc.sum"))
  {
    my $obs_priant_file = $cfg{"SERVER_RESULTS_DIR"}."/".$o."/obs.priant";
    my $obs_antenna_file = $cfg{"SERVER_RESULTS_DIR"}."/".$o."/obs.antenna";

    # band_tsamp is the effective time resolution of the whole band, which should be 1/BW
    my $band_tsamp = 1.0 / $bw;
    Dada::logMsg(2, $dl, "processCorrObservation: bw=".$bw." band_tsamp=".$band_tsamp);

    #my $tsamp = 1.28;
    #if ($hires)
    #{
    #  $tsamp = 10.24;
    #}
    #my $band_tsamp = $tsamp / $nchan;
    #Dada::logMsg(2, $dl, "processCorrObservation: tsamp=".$tsamp." nchan=".$nchan." band_tsamp=".$band_tsamp);

    # get the ranked antennas from file
    open(FH,"<".$obs_priant_file) or return ("fail", "could not open ".$obs_priant_file." for reading");
    my @pas = <FH>;
    close (FH);
  
    my ($ant_a, $ant_a_idx, $ant_b, $ant_b_idx);

    $ant_b = "";
    $ant_a = $pas[0];
    chomp $ant_a;
    my $bay_a = substr($ant_a, 0, 3);
    my $mod_a = substr($ant_a, 1, 2);

    my $pa;
    for ($i=1; $i<=$#pas; $i++)
    { 
      $pa = $pas[$i];
      chomp $pa;

      # check if in same bay and check that bay offset is > 2 at least
      if (($ant_b eq "") && (substr($pa,0,3) ne $bay_a) && (abs(substr($pa,1,2) - $mod_a) > 2))
      {
        $ant_b = $pa;
      }
    }

    Dada::logMsg(2, $dl, "processCorrObservation: ant_a=".$ant_a." ant_b=".$ant_b);

    # now find the antenna indexes for these modules
    $cmd = "grep -n ".$ant_a." ".$obs_antenna_file." | awk -F: '{print \$1}'";
    Dada::logMsg(2, $dl, "processCorrObservation: ".$cmd);
    ($result, $ant_a_idx) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$ant_a_idx);
    if ($result ne "ok")
    {
      Dada::logMsgWarn($warn, "processCorrObservation: ".$cmd." failed: ".$response);
      return ("fail", "failed to solve for delays");
    }

    $cmd = "grep -n ".$ant_b." ".$obs_antenna_file." | awk -F: '{print \$1}'";
    Dada::logMsg(2, $dl, "processCorrObservation: ".$cmd);
    ($result, $ant_b_idx) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$ant_b_idx);
    if ($result ne "ok")
    {
      Dada::logMsgWarn($warn, "processCorrObservation: ".$cmd." failed: ".$response);
      return ("fail", "failed to solve for delays");
    }
    
    $ant_a_idx -= 1;
    $ant_b_idx -= 1;

    # for plot and obs.delays output file generation
    chdir $cfg{"SERVER_RESULTS_DIR"}."/".$o;

    $cmd = "mopsr_solve_delays ".$corr_nchan." ".$results_dir."/cc.sum obs.antenna -s ".$s." -t ".$band_tsamp." -p -a ".$ant_a_idx." -d ".$ant_b_idx." -r /home/dada/copradar";
    if ($hires)
    {
      $cmd = "mopsr_solve_delays ".$corr_nchan." ".$results_dir."/cc.sum obs.antenna -s ".$s." -t ".$band_tsamp." -p -a ".$ant_a_idx." -d ".$ant_b_idx." -r /home/dada/copradar_hires_extra";
    }
    Dada::logMsg(2, $dl, "processCorrObservation: ".$cmd);
    ($result, $response) = Dada::mySystem($cmd);
    Dada::logMsg(3, $dl, "processCorrObservation: ".$result." ".$response);
    chdir $cfg{"SERVER_RESULTS_DIR"};
    if ($result ne "ok")
    {
      Dada::logMsgWarn($warn, "processCorrObservation: ".$cmd." failed: ".$response);
      return ("fail", "failed to solve for delays");
    }
  }
}


sub appendCorrFile($$$)
{
  my ($results_dir, $file, $nant) = @_;

  my ($cmd, $result, $response, $bf_file, $plus);
  my @bf_files;

  $cmd = "find ".$results_dir." -name '".$file."' | sort -n";
  Dada::logMsg(2, $dl, "appendCorrFile: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "appendCorrFile: ".$result." ".$response);
  if ($result ne "ok")
  {
    Dada::logMsg(0, $dl, "appendCorrFile: ".$cmd." failed: ".$response);
    return ("fail", "could not get file list");
  }

  @bf_files = split(/\n/, $response);
  $cmd = "mopsr_corr_fsum ".$nant." ";

  $plus = "-a";
  if ($file =~ m/\.cc$/)
  {
    $plus = "-c";
  }
  
  foreach $bf_file (@bf_files)
  {
    $cmd .= " ".$plus." ".$bf_file;
  }

  $cmd .= " ".$results_dir."/".$file;

  Dada::logMsg(2, $dl, "appendCorrFile: ".$cmd);
  ($result, $response) = Dada::mySystem($cmd);
  Dada::logMsg(3, $dl, "appendCorrFile: ".$result." ".$response);
  if ($result ne "ok")
  {
    Dada::logMsg(0, $dl, "appendCorrFile: ".$cmd." failed: ".$response);
    return ("fail", "could not get file list");
  }

  foreach $bf_file (@bf_files)
  {
    unlink $bf_file;
  }

  return ("ok", $file);
}


###############################################################################
#
# Handle quit requests asynchronously
#
sub controlThread($$) {

  Dada::logMsg(1, $dl ,"controlThread: starting");

  my ($quit_file, $pid_file) = @_;

  Dada::logMsg(2, $dl ,"controlThread(".$quit_file.", ".$pid_file.")");

  # Poll for the existence of the control file
  while ((!(-f $quit_file)) && (!$quit_daemon)) {
    sleep(1);
  }

  # ensure the global is set
  $quit_daemon = 1;

  if ( -f $pid_file) {
    Dada::logMsg(2, $dl ,"controlThread: unlinking PID file");
    unlink($pid_file);
  } else {
    Dada::logMsgWarn($warn, "controlThread: PID file did not exist on script exit");
  }

  Dada::logMsg(1, $dl ,"controlThread: exiting");

  return 0;
}
  


#
# Handle a SIGINT or SIGTERM
#
sub sigHandle($)
{
  my $sigName = shift;
  print STDERR $daemon_name." : Received SIG".$sigName."\n";
  if ($quit_daemon)
  {
    print STDERR $daemon_name." : Exiting\n";
    exit 1;
  }
  $quit_daemon = 1;
}

# 
# Handle a SIGPIPE
#
sub sigPipeHandle($)
{
  my $sigName = shift;
  print STDERR $daemon_name." : Received SIG".$sigName."\n";
} 


# Test to ensure all module variables are set before main
#
sub good($) {

  my ($quit_file) = @_;

  # check the quit file does not exist on startup
  if (-f $quit_file) {
    return ("fail", "Error: quit file ".$quit_file." existed at startup");
  }

  # the calling script must have set this
  if (! defined($cfg{"INSTRUMENT"})) {
    return ("fail", "Error: package global hash cfg was uninitialized");
  }

  # this script can *only* be run on the configured server
  if (index($cfg{"SERVER_ALIASES"}, Dada::getHostMachineName()) < 0 ) {
    return ("fail", "Error: script must be run on ".$cfg{"SERVER_HOST"}.
                    ", not ".Dada::getHostMachineName());
  }

  # Ensure more than one copy of this daemon is not running
  my ($result, $response) = Dada::checkScriptIsUnique(basename($0));
  if ($result ne "ok") {
    return ($result, $response);
  }

  return ("ok", "");
}


END { }

1;  # return value from file
