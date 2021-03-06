#!/usr/bin/perl -T
#
#  Author: Hari Sekhon
#  Date: 2013-01-14 20:50:13 +0000 (Mon, 14 Jan 2013)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#

$DESCRIPTION = "Prints files from one or more Hadoop HDFS directory trees (default /tmp) that are older than the given Days Hours Mins. Deletes files if specifying --rm

Credit to my old colleague Rob Dawson @ Specific Media for giving me this idea during lunch

Tested on CDH 4.x and HDP 2.1";

$VERSION = "0.8.2";

use strict;
use warnings;
use Time::Local;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils qw/:DEFAULT :regex/;

$ENV{"PATH"} .= ":/opt/hadoop/bin:/usr/local/hadoop/bin";

my $default_hadoop_bin = "hadoop";
my $hadoop_bin = $default_hadoop_bin;

my $DEFAULT_PATH = "/tmp";
my $path; # don't set this, need to check if user did or used @ARGV

my $days  = 0;
my $hours = 0;
my $mins  = 0;
my $include;
my $exclude;
my $skipTrash = "";
my $rm    = 0;
my $batch = 0;
my $max_batch_size = 1500; # argument list too long error > 1500
my $Xmx;

set_timeout_max(86400);    # 1 day max -t timeout
set_timeout_default(1800); # 30 mins. hadoop fs -lsr /tmp took 6 minutes to list 1720943 files/dirs on my test cluster!

my %months = (
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
);

%options = (
    "d|days=i"      =>  [ \$days,       "Number of days after which to delete files" ],
    "H|hours=i"     =>  [ \$hours,      "Number of hours after which to delete files" ],
    "m|mins=i"      =>  [ \$mins,       "Number of minutes after which to delete files" ],
    "p|path=s"      =>  [ \$path,       "Path for which to remove old files (default: $DEFAULT_PATH)" ],
    "i|include=s"   =>  [ \$include,    "Include Regex of files, for optional filtering" ],
    "e|exclude=s"   =>  [ \$exclude,    "Exclude Regex of files, optional, takes priority over --include" ],
    "rm"            =>  [ \$rm,         "Actually launch the hadoop fs -rm commands on the files, by default this script only prints the hadoop fs -rm commands. WARNING: only use this switch after you have checked what the list of files to be removed is, otherwise you may lose data" ],
    "skipTrash"     =>  [ \$skipTrash,  "Skips moving files to HDFS Trash, reclaims space immediately" ],
    "hadoop-bin=s"  =>  [ \$hadoop_bin, "Path to 'hadoop' command if not in \$PATH" ],
    "b|batch=s"     =>  [ \$batch,      "Batch the deletes in groups of N files for efficiency (max $max_batch_size). You will almost certainly need to use this in Production" ],
    "Xmx=s"         =>  [ \$Xmx,        "Max Heap to assign to the 'hadoop' or 'hdfs' command in MB, must be an integer, units cannot be specified" ],
);
@usage_order = qw/days hours mins path include exclude rm skipTrash batch hadoop-bin/;
get_options();

my $print_only = 1;
if ($rm and not $debug){
    $print_only = 0; # actually run the hadoop fs -rm command instead of just echo'ing it out
}
$skipTrash = "-skipTrash" if $skipTrash;
usage unless ($days or $hours or $mins);

$days    = validate_float($days,  "days",  0, 3650);
$hours   = validate_float($hours, "hours", 0, 23);
$mins    = validate_float($mins,  "mins",  0, 59);
my $max_age_secs = ($days * 86400) + ($hours * 3600) + ($mins * 60);
usage "must specify a total max age > 5 minutes" if ($max_age_secs < 300);
my @paths = ();
push(@paths, validate_filename($path, 0, "path")) if defined($path); # because validate_dir[ectory] checks the directory existance on the local filesystem
foreach(@ARGV){
    push(@paths, validate_filename($_, 0, "path") );
}
if(@paths){
    $path = "'" . join("' '", uniq_array @paths) . "'";
} else {
    $path = "'$DEFAULT_PATH'";
}
if(defined($include)){
    $include     = validate_regex($include, "include");
    $include     = qr/$include/o;
}
if(defined($exclude)){
    $exclude     = validate_regex($exclude, "exclude");
    $exclude     = qr/$exclude/o;
}
if($Xmx){
    $Xmx =~ /^(\d+)$/ or usage "-Xmx must be an integer representing the number of MB to allocate to the Heap";
    $Xmx = $1;
    vlog_options "Xmx (Max Heap MB)", $Xmx; 
}
$hadoop_bin  = which($hadoop_bin, 1);
$hadoop_bin  =~ /\b\/?hadoop$/ or die "invalid hadoop program '$hadoop_bin' given, should be called hadoop!\n";
$batch       = validate_int($batch, "batch size", 0, $max_batch_size);
vlog_options "rm",          $rm        ? "true" : "false";
vlog_options "skipTrash",   $skipTrash ? "true" : "false";
vlog_options "hadoop path", $hadoop_bin;
vlog2;

# might leave a hadoop fs -rm running when we exit but I don't want to submit a kill sub to timeout in case it interferes with any other hadoop fs -rm command any user might be executing on the same system.
set_timeout();

go_flock_yourself();

my $cmd   = "hadoop fs -ls -R $path"; # is quoted above when processing $path or @paths;
if($Xmx){
    $cmd = "HADOOP_HEAPSIZE='$Xmx' $cmd";
}
my $fh    = cmd("$cmd | ", 0, 1) or die "ERROR: $? returned from \"$cmd\" command: $!\n";
my @files = ();
my $now   = time || die "Failed to get epoch timestamp\n";
my $file_count     = 0;
my $files_removed  = 0;
my $excluded_count = 0;
my $script_excluded_count = 0;
vlog "processing file list";
while (<$fh>){
    vlog3 "output: $_";
    chomp;
    my $line = $_;
    $line =~ /^Found\s\d+\sitems/ and next;
    if($line =~ /^([d-])$rwxt_regex\+?\s+(?:\d+|-)\s+[\w-]+\s+[\w-]+\s+\d+\s+(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s+($filename_regex)$/){
        my $dir      = $1;
        next if $dir eq "d"; # Not supporting dirs as there is no -rmdir and it would require a dangerous -rmr operation and should therefore be done by hand
        $file_count++;
        my $year     = $2;
        my $month    = $3;
        my $day      = $4;
        my $hour     = $5;
        my $min      = $6;
        my $filename = $7;
        $month = $months{$month} if grep { $month eq $_} keys %months;
        my $tstamp   = timelocal(0, $min, $hour, $day, $month-1, $year) || die "$progname: Failed to convert timestamp $year-$month-$day $hour:$min for comparison\n";
        if( ($now - $tstamp ) > $max_age_secs){
            if (defined($exclude) and $filename =~ $exclude){
                $excluded_count += 1;
                next;
            }
            # - Some additional safety stuff, do not mess with /tmp/mapred or /hbase !!!!
            # - or .Trash...
            # - or now /solr has been added...
            # - oh and I should probably omit the CM canary files given I work for Cloudera now...
            # - Also, omitting the Hive warehouse directory since removing Hive managed tables seems scary
            # - share/lib/ is under /user/oozie, don't remove that either
            # - not anchoring /tmp intentionally since hadoop fs -ls ../../tmp results in ../../tmp and without anchor this will still exclude
            # - added /apps/ to cover /apps/hive, /apps/hbase, /apps/hcatalog on HDP
            if ($filename =~ qr{ 
                                    /tmp/mapred/ |
                                    /apps/       |
                                    /hbase/      |
                                    /solr/       |
                                    \.Trash/     |
                                    warehouse/   |
                                    share/lib/   |
                                    \.cloudera_health_monitoring_canary_files |
                                    [\'\"\`] |
                                    \$\(
                                    }ix){
                $script_excluded_count++;
                next;
            }
            if(defined($include)){
                if($filename =~ $include){
                    push(@files, $filename);
                    $files_removed++;
                }
            } else {
                push(@files, $filename);
                $files_removed++;
            }
        }
    } else {
        warn "$progname: WARNING - failed to match line from hadoop output: \"$line\"\n";
    }
    if(@files and $batch < 2){
        # Not setting HADOOP_HEAPSIZE here since it should be suffient for such a small number of files
        $cmd = "hadoop fs -rm $skipTrash '" . join("' '", @files) . "'";
        if($print_only){
            print "$cmd\n";
        } else {
            system($cmd);
            if($? == 0){
                # OK
            } elsif($? == 33280){
                die "Control-C\n";
            } else {
                die "ERROR: $? returned from command \"hadoop fs -rm ...\": $!\n";
            }
        }
        @files = ();
    }
}
$file_count or die "No files found in HDFS\n";
if(@files and $batch > 1){
    vlog scalar @files . " files " . ($print_only ? "matching" : "to be deleted" );
    my $ARG_MAX = `getconf ARG_MAX`;
    isInt($ARG_MAX) or code_error "failed to get ARG_MAX from 'getconf ARG_MAX', got a non-integer '$ARG_MAX'";
    # This doesn't work for some reason even when submitting 821459 against an ARG_MAX of 2621440 it results in ERROR: -1 returned from command "hadoop fs -rm ...": Argument list too long
    # taken from xargs --show-limits, use the more restrictive of the two numbers
    if($ARG_MAX > 131072){
        $ARG_MAX = 131072;
        vlog2 "override ARG_MAX to use 131072";
    }
    for(my $i=0; $i < scalar @files; $i += $batch){
        my $last_index = $i + $batch - 1;
        if($last_index >= scalar @files){
            $last_index = scalar(@files) - 1;
        }
        vlog "file batch " . ($i+1) . " - " . ($last_index+1) . ":";
        $cmd = "hadoop fs -rm $skipTrash '" . join("' '", @files[ $i .. $last_index ]) . "'";
        if($Xmx){
            $cmd = "HADOOP_HEAPSIZE='$Xmx' $cmd";
        }
        #vlog2 "checking getconf ARG_MAX to make sure this batch command isn't too big";
        # add around 2000 for environment and another 2000 for safety margin
        if((length($cmd) + 2000 + 2000) < $ARG_MAX){
            vlog2 "command length: " . length($cmd) . "  ARG_MAX: $ARG_MAX";
        } else {
            die "Here is the would-be command:\n\n$cmd\n\nResulting hadoop fs -rm command length (" . length($cmd) . ") + env allowance (2000) + safety margin (2000) > operating system's ARG_MAX ($ARG_MAX). Review and reduce batch size if necessary, this may be caused by very long filenames coupled with large batch size.\n\n"
        }
        if($print_only){
            print "$cmd\n";
        } else {
            system($cmd);
            if($? == 0){
                # OK
            } elsif($? == 33280){
                die "Control-C\n";
            } else {
                die "ERROR: $? returned from command \"hadoop fs -rm ...\": $!\n";
            }
        }
    }
}

plural $file_count;
$msg = "$progname Complete - %d file$plural checked, $excluded_count excluded, ";
$msg .= "$script_excluded_count hardcoded excluded for safety, " if $script_excluded_count;
plural $files_removed;
$msg .= "%d file$plural older than %s days %s hours %s mins " . ($print_only ? "" : "removed") . "\n";
warn sprintf($msg, $file_count, $files_removed, $days, $hours, $mins);
