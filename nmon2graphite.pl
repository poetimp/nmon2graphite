#!/usr/bin/perl -w
#------------------------------------------------------------------------------------------
#
# Program: nmon2graphite
# Author:  Paul Lemmons
# Date:    09/05/2017
# Description:
#          This program will read a file generated by nmon, running in batch mode
#          and will send the information to the graphite/whisper database used by 
#          grafana. For this program to work the following three lines need to be included  
#          the crontab:
#
# 00   00 * * * find /nmondata -name "`hostname`_`date +\%y\%m\%d`*.nmon" -mtime +7  | xargs rm
# 00   00 * * * (cd  /nmondata && /usr/local/bin/nmon -f -s 30 -c 2880)
# */2  *  * * * (cd  /nmondata && /usr/local/bin/nmon2graphite.pl `hostname`_`date +\%y\%m\%d`*.nmon)
# 
# Also it is assumed that the /nmondata directory exists and is where the nmon data is being kept.
# Note also that the location of the nmon command is different between AIX and Linux. Update
# the crontab entry above as needed. 
#------------------------------------------------------------------------------------------
#  C H A N G E   H I S T O R Y
#------------------------------------------------------------------------------------------
#  09/05/2017    Paul Lemmons   Initial setup.
#  10/16/2017    Paul Lemmons   Hopefully addresses out of memory issue
#  10/24/2017    Paul Lemmons   Still working on out of memory problem
#                               Lots of changes but the majr ones are:  
#                                 - Debug log
#                                 - Memory utilization tracing
#                                 - Stagger the requests to grafana database
#  10/30/2017    Paul Lemmons   Found memory problem. Caused by grafana database queries
#                               getting a server 500 error. If we ge oe of thise retry
#                               a few times before giving up.
#------------------------------------------------------------------------------------------
use strict;
use List::Util qw[min max];
use Scalar::Util qw(looks_like_number);
use POSIX qw(strftime);
use IO::Socket::INET;
use LWP::UserAgent;
use Time::Local;
use JSON;

#-----------------------------------------------------------------------------------------------
# Subroutine prototypes
#-----------------------------------------------------------------------------------------------
sub graphiteLastTimeStamp();
sub debugPrint($);
 
#-----------------------------------------------------------------------------------------------
# This make it possible for the debugger to break on a warninig
# Add these lines where you want to have the breakpoint:
#$DB::single ||= $warn_flag;  # Set a brealpoint if the warnflag is set
#    $warn_flag = 0           # unset the warn flag whether it is set or not
#-----------------------------------------------------------------------------------------------

$|                = 1;         # Unbuffer IO
my  $DEBUG        = 1;         # Set to 1 for traced output
my  $DEBUGMEM     = 1;         # Set to 1 for memory usage output
my  $KEEPDEBUGLOG = 0;         # Should I keep the debug log if program exits successfully?
our $warn_flag    = 0;         # Warn flag is off to start with
$SIG{__WARN__} = sub { $warn_flag = 1; CORE::warn(@_) }; # If a warninng happens set the flag 
                                                         # to 1 and issue the warninig 
my $debugLog = "/tmp/nmon2graphite.".time().".log";

if ($DEBUG and $DEBUGMEM)
{
   eval "use Devel::Size qw(size total_size);"; # to see if module is available. 
   #If not disable Memory reporting
   if ($@)
   {
      $DEBUGMEM=0;
      debugPrint("Memory debug turned off: [Module not installed]\n");
   }
   else
   {
      debugPrint("Memory debug turned on\n");
   }
}

#-----------------------------------------------------------------------------------------------
# Instantiate communication modules
#-----------------------------------------------------------------------------------------------

my $ua       = new LWP::UserAgent();
#-----------------------------------------------------------------------------------------------
# The connection information for the graphite/whisper datbase server
#-----------------------------------------------------------------------------------------------
our $graphiteProt      = 'http';
our $graphiteHost      = 'graphite.host.com';
our $graphiteReadPort  = '81';
our $graphiteWritePort = '2003';
our $graphitePrefix    = 'nmon';
our $graphiteMaxTime   = '';
our $hostname          = '';
our $hosttype          = '';
our $fromDateTime      = '';

#-----------------------------------------------------------------------------------------------
# Global variable
#-----------------------------------------------------------------------------------------------
my $today         = timelocal(0,0,0, (localtime)[3,4,5]); # midnight today
#-----------------------------------------------------------------------------------------------
# Read the file supplied on the command line or piped into this script
#-----------------------------------------------------------------------------------------------
debugPrint("Starting\n");
if (@ARGV == 0)
{
   die "No input files specified on the command line"
}
else
{
   foreach my $nmonFile (@ARGV)
   {
      debugPrint("Processing file: $nmonFile\n");
      
      my %descriptors   = ();
      my %perfData      = ();
      my $startTime     = '';
      my $startDate     = '';
  
      #------------------------------------------------------------------------------------------------
      # Make sure file is stable - has not been modified for at least 15 seconds
      #------------------------------------------------------------------------------------------------
      my $age = time()-(stat($nmonFile))[9];
      while($age < 15)
      {
         debugPrint("Waiting for file to stabalize. Age $age second ...\n");
         sleep(15-$age+1);
         $age = time()-(stat($nmonFile))[9];
      }
      #------------------------------------------------------------------------------------------------
      # Process the file
      #------------------------------------------------------------------------------------------------
      open(NMON,$nmonFile) or die "Unable to open the file: $nmonFile: $!\n";
      debugPrint("Top of consuming loop\n");
      while(defined(my $line = <NMON>))
      {
         chomp($line);
         my @fields = split(/,/,$line);
         
         #------------------------------------------------------------------------------------------------
         # Capture the hostname and start timestamp for this data. Also ascertain the latest timestamp
         # that has been recorded in the graphite database
         #------------------------------------------------------------------------------------------------
         if ($fields[0] =~ /^AAA/)
         {
            debugPrint("\tAAA Record: ".$fields[1]."\n");
            if   ($fields[1] =~ /date/)   {$startDate  = $fields[2];}
            elsif($fields[1] =~ /time/)   {$startTime  = $fields[2];}
            elsif($fields[1] =~ /host/)   {$hostname   = $fields[2];}
            elsif($fields[1] =~ /AIX/)    {$hosttype   = 'AIX';}
            elsif($fields[1] =~ /OS/ 
              and $fields[2] =~ /Linux/i) {$hosttype   = 'Linux';}
            
            # If we have all of the parts nessessary and we have not already done so, convert literary 
            # time to unix time stamp
            if ($graphiteMaxTime eq '' and $startDate ne '' and $startTime ne '')
            {
               my @dateParts     = split(/-/,$startDate);
               my @timeParts     = split(/[:\.]/,$startTime);
               $fromDateTime     = $timeParts[0].':'.
                                   $timeParts[1].'_'. 
                                   $dateParts[2].
                                   sprintf("%02d",(index('JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC',$dateParts[1])/3)+1).
                                   $dateParts[0];
               $graphiteMaxTime  = graphiteLastTimeStamp();
            }
         }
         #------------------------------------------------------------------------------------------------
         # Ignore the BBB data. Not sure what I would do with it if I had it
         #------------------------------------------------------------------------------------------------
         elsif  ($fields[0] =~ /^BBB/)
         {
            # Do nothing with this data.
         }
         #------------------------------------------------------------------------------------------------
         # Capture field names and tags 
         #------------------------------------------------------------------------------------------------
         elsif  ($fields[1] !~ /^T\d+/)
         {
            debugPrint("\tHeadings Record: ".$fields[0]."\n");
            $descriptors{$fields[0]} = {'title'    => $fields[1], 
                                        'headings' => []};
            my $i=2;
            while(defined($fields[$i]))
            {
               # These heading will become the names of the items in the DB... make them reasonable
               my $itemName =  $fields[$i];
                  $itemName =~ s/\/s/-PerSec/g; # /'s are shortcuts for "per" so spell it out
                  $itemName =~ s/\%/Pct/g;      # Spell out Percent... sorta
                  $itemName =~ s/\-/_/g;        # consistency in separaters
                  $itemName =~ s/$hostname//g;  # AIX like to add hostname... remove it
                  $itemName =~ s/ +/_/g;        # Spaces become underscores
                  $itemName =~ s/\(/_/g;        # OpenParen make a _
                  $itemName =~ s/\)//g;         # CloseParen make go away
                  
               push(@{$descriptors{$fields[0]}->{'headings'}},$itemName);
               $i++;
            }
         }  
         #------------------------------------------------------------------------------------------------
         # Capture all of the nmon snapshots into a hash. Only record the snapshots that occur after the 
         # lastest time found in the graphite database.
         #------------------------------------------------------------------------------------------------
         elsif  ($fields[1] =~ /^T\d+/)
         {
            if ($fields[0] =~ /^ZZZZ/)
            {
               my $timeStr   = $fields[2];
               my $dateStr   = $fields[3];
               my @dateParts = split(/-/,$dateStr);
               my @timeParts = split(/:/,$timeStr);
               my $dateTime  = $timeParts[2].':'.
                               $timeParts[1].':'.
                               $timeParts[0].' '. 
                               $dateParts[0].'-'.
                               sprintf("%02d",index('JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC',$dateParts[1])/3).'-'.
                               $dateParts[2].' ';
               
               
               my $ZZZTime = timelocal(split(/[\s\-:]+/,$dateTime));
               
               if ($ZZZTime > $graphiteMaxTime and $ZZZTime > $today)
               {
                  debugPrint("\tZZZZ Record: ".$fields[2]."\tUnixtime: $ZZZTime\n");
                  $perfData{$fields[1]}->{'timestamp'} = $ZZZTime;
                  $perfData{$fields[1]}->{'time'}      = $timeStr;
                  $perfData{$fields[1]}->{'date'}      = $dateStr;
               }
               else
               {
                  debugPrint("\tZZZZ Record: ".$fields[2]."\tUnixtime: $ZZZTime - Skipped Out of range\n");
               }
            }
            #---------------------------------------------------------------------------------------------
            # only collect the data if it pertains to today and we have not already captured it earlier
            #---------------------------------------------------------------------------------------------
            else
            {  
               if(defined($perfData{$fields[1]}))
               {
                  debugPrint("\tData Record: ".$fields[1]."\ttype: ".$fields[0]."\tTmestamp: ".$perfData{$fields[1]}->{'timestamp'}."\n");
                  my $i=2;
                  while(defined($fields[$i]))
                  {
                     if (defined($fields[$i]) and defined($descriptors{$fields[0]}->{'headings'}[$i-2]))
                     {
                        $perfData{$fields[1]}->{$fields[0]}->{$descriptors{$fields[0]}->{'headings'}[$i-2]} = $fields[$i];
                        $DB::single ||= $warn_flag;
                        $DB::single ||= $warn_flag; # Duplicated to get past "Only used once" warning. Yeah, dumb but whatever.
                        $warn_flag = 0
                     }
                     $i++;
                  }
               }
               else
               {
                  debugPrint("\tData Record: ".$fields[1]."\ttype: ".$fields[0]."tSkipped: timestamp out of range.\n");
               }
            }
         } 
      }
      close(NMON);
      debugPrint("Done with consuming loop\n");
      #---------------------------------------------------------------------------------------------------
      # If we have a valid input fie, the following variables will have values 
      #---------------------------------------------------------------------------------------------------
      
      if ($hostname  eq '') {die('unable to glean hostname from input file')}
      if ($hosttype  eq '') {die('unable to glean hosttype from input file')}
      if ($startDate eq '') {die('unable to glean start date from input file')}
      if ($startTime eq '') {die('unable to glean start time from input file')}
     
      #---------------------------------------------------------------------------------------------------
      # Process the data collected into graphite/whisper database 
      #---------------------------------------------------------------------------------------------------
      debugPrint("Size of %perfData Structure: ".size(\%perfData)."\n")       if $DEBUGMEM;  #MEMORY
      debugPrint("Total Size of %perfData    : ".total_size(\%perfData)."\n") if $DEBUGMEM;  #MEMORY
      #---------------------------------------------------------------------------------------------------
      # In nmon terms a snapshot is a point in time look at the system. Go through each snapshot and
      # send the data to graphite/whisper 
      #---------------------------------------------------------------------------------------------------
      debugPrint("starting main processing loop\n");
      my $graphiteData='';
      foreach my $snapshot (sort(keys(%perfData)))
      {
         #================================================================================================================
         # Initialize top level graphite nodes
         #================================================================================================================
         my $timeStamp = $perfData{$snapshot}->{'timestamp'};
          
         debugPrint("$snapshot\n");
         my $metricType='';
      
         debugPrint("\tStarting metric processing loop\n");
         foreach my $metric (sort(keys(%{$perfData{$snapshot}})))
         {
            debugPrint("\t$metric\n");
            
            if   ($metric =~ /^MEM/ 
               or $metric =~ /^VM/)            {$metricType='memory'}
            elsif($metric =~ /^CPU/)           {$metricType='cpu'}
            elsif($metric =~ /^PROC/)          {$metricType='processor'}
            elsif($metric =~ /^NET/)           {$metricType='network'}
            elsif($metric =~ /^DISK/)          {$metricType='disk'}
            else                               {$metricType='IGNORE';}
         
            if ($metricType ne 'IGNORE')
            {
               foreach my $item (sort(keys(%{$perfData{$snapshot}->{$metric}})))
               {
                  debugPrint("\t\t$item:\t".$perfData{$snapshot}->{$metric}->{$item}."\n");
                  if ($perfData{$snapshot}->{$metric}->{$item} ne '')
                  {
                     if (looks_like_number($perfData{$snapshot}->{$metric}->{$item}))
                     {
                        $perfData{$snapshot}->{$metric}->{$item} += 0;
                        $graphiteData .= $graphitePrefix                          . '.'
                                      .  'ostype'                                 . '.'
                                      .  $hosttype                                . '.'
                                      .  'hostname'                               . '.'
                                      .  $hostname                                . '.'
                                      .  $metricType                              . '.'
                                      .  $metric                                  . '.'
                                      .  $item                                    . ' '
                                      .  $perfData{$snapshot}->{$metric}->{$item} . ' '
                                      .  $timeStamp                               . "\n"
                                      ;
                        debugPrint("\t\t\tSize of graphiteData: ".size(\$graphiteData)."\n") if $DEBUGMEM;  #MEMORY
                     }
                     else
                     {
                        debugPrint("NOT NUMERIC: Snapshot: $snapshot, Metric: $metric, Item: [$item]\n");
                     }
                  }
               }
            }
         }
      }
      debugPrint("Finished main processing loop\n");
      debugPrint("\nSize of graphiteData: ".size(\$graphiteData)."\n") if $DEBUGMEM;   #MEMORY
      debugPrint("\n$graphiteData\n");
      #---------------------------------------------------------------------------------------------------
      # Setup for connection to Graphite service send the data and close conection
      #---------------------------------------------------------------------------------------------------
      
      debugPrint("sending data to graphite\n");
      my $graphite = IO::Socket::INET->new(PeerAddr   =>   $graphiteHost,
                                           PeerPort   =>   $graphiteWritePort,
                                           Proto      =>   'tcp'
                                          );
      $graphite or die("Can't connect to $graphiteHost:$graphiteWritePort");
      $graphite->autoflush(1);
         
      $graphite->send($graphiteData);
      $graphite->shutdown(1);
      close $graphite;
      debugPrint("Data Sent\n");
   }
}

#---------------------------------------------------------------------------------------------------
# Kill the debug log if we exited successfully unless we really wanted to keep it
#---------------------------------------------------------------------------------------------------

unlink($debugLog) if $DEBUG and !$KEEPDEBUGLOG;        # Possibly cleanup on successful run 

#---------------------------------------------------------------------------------------------------
# Write messages to a debug log when debug is turned on. Force unbuffered by opening and closing 
# for each message. Slow but this is debug only so not a real issue.  
#---------------------------------------------------------------------------------------------------
sub debugPrint($)
{
   use POSIX qw(strftime);
   if ($DEBUG)
   {
      my $msg = shift;
      my $now = strftime(" %H:%M:%S",localtime);
      
      open (DEBUGLOG,">>$debugLog") or die("Unable to open Debug Log:$debugLog: $!\n");
      print DEBUGLOG "[$now] : $msg";
      close(DEBUGLOG);
   }
}
#---------------------------------------------------------------------------------------------------
# Query the graphite databse and see what the latest data point is so that we don't repeat data
# in the database
#---------------------------------------------------------------------------------------------------
sub graphiteLastTimeStamp()
{
   my $staggerSeconds = int(rand(120)); # try to stagger the requests against the grafana database
   debugPrint("Staggering the request to the grafana database by waiting $staggerSeconds before making the request\n");
   sleep($staggerSeconds);
   
   debugPrint("Retrieving the last update time\n");
   my $url      = "$graphiteProt://$graphiteHost:$graphiteReadPort/render?target=$graphitePrefix.ostype.$hosttype.hostname.$hostname.cpu.CPU_ALL.*&format=json&from=$fromDateTime";
   my $maxAge   = $today; # set max age to today just in ase we cannot find it in the database

   my $response = 0;;
   my $tries    = 0;
   do
   {
      $response = $ua->post($url, "Content-Type"=>"application/json");
      $tries++;

      if ( $response->is_success() ) 
      {
         my $content  = $response->content;
         my $jsonresp = decode_json($content);

         if (scalar(@{$jsonresp}) > 0)
         {
            foreach my $target (@{$jsonresp})
            {
               my $count = scalar(@{$target->{'datapoints'}});
               if ($count > 0)
               {
                  for my $dp (@{$target->{'datapoints'}})
                  {
                     my $value     = defined($dp->[0]) ? $dp->[0] : "UDF";
                     my $timestamp = defined($dp->[1]) ? $dp->[1] : "UDF";

                     if ($value ne "UDF")
                     {
                        $maxAge = max($maxAge,$timestamp);
                     }
                  }
               }
               else
               {
                  debugPrint("Unable to ascertain the latest date in the database: No Datapoint objects returned\n");
               }
            }
         }
         else
         {
            debugPrint("Unable to ascertain the latest date in the database: No JSON objects returned\n");
         }
      }
      else
      {
         debugPrint("Unable to ascertain the latest date in the database: ".$response->status_line."\n");
         if ($tries <= 3)
         {
            $staggerSeconds = int(rand(60)); # try to stagger the requests against the grafana database
            debugPrint("Retrying in $staggerSeconds seconds\n");
            sleep($staggerSeconds);
         }
      }
   } until ($response->is_success() or $tries > 3);

   debugPrint("Returning max age: $maxAge\n");
   return $maxAge;
}
