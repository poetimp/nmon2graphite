#!/usr/bin/perl -w
#------------------------------------------------------------------------------------------
# Program: nmon2graphite
# Author:  Paul Lemmons
# Date:    09/05/2017
# Description:
#          This program will find read a file generated by nmon, running in batch mode
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
#  09/05/2017    Paul Lemmons                  Initial setup.
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

#-----------------------------------------------------------------------------------------------
# Instantiate communication modules
#-----------------------------------------------------------------------------------------------
my $ua       = new LWP::UserAgent();
#-----------------------------------------------------------------------------------------------
# The connection information for the graphite/whisper datbase server
#-----------------------------------------------------------------------------------------------
our $graphiteProt     = 'http';
our $graphiteHost     = 'graphite.host.com';
our $graphiteReadPort = '81';
our $graphitePrefix   = 'nmon';
our $graphiteMaxTime  = '';
our $hostname         = '';
our $hosttype         = '';
our $fromDateTime     = '';

#-----------------------------------------------------------------------------------------------
# Global variable
#-----------------------------------------------------------------------------------------------
my $today         = timelocal(0,0,0, (localtime)[3,4,5]); # midnight this morning
my %descriptors   = ();
my %perfData      = ();
my $startTime     = '';
my $startDate     = '';
#-----------------------------------------------------------------------------------------------
# Read the file supplied on the command line or piped into this script
#-----------------------------------------------------------------------------------------------
while(defined(my $line = <>))
{
   chomp($line);
   my @fields = split(/,/,$line);
   
   #------------------------------------------------------------------------------------------------
   # Capture the hostname and start timestamp for this data. Also ascertain the latest timestamp
   # that has been recorded in the graphite database
   #------------------------------------------------------------------------------------------------
   if ($fields[0] =~ /^AAA/)
   {
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
   elsif  ($fields[1] =~ /^BBB /)
   {
      # Do nothing with this data.
   }
   #------------------------------------------------------------------------------------------------
   # Capture field names and tags 
   #------------------------------------------------------------------------------------------------
   elsif  ($fields[1] !~ /^T\d+/)
   {
      my $itemName =
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
         
         $perfData{$fields[1]}->{'time'}      = $timeStr;
         $perfData{$fields[1]}->{'date'}      = $dateStr;
         
         $perfData{$fields[1]}->{'timestamp'} = timelocal(split(/[\s\-:]+/,$dateTime));
      }
      #---------------------------------------------------------------------------------------------
      # only collect the data if it pertains to today and we have not already captured it earlier
      #---------------------------------------------------------------------------------------------
      else
      {  
         if(defined($perfData{$fields[1]}->{'timestamp'})           and 
            $perfData{$fields[1]}->{'timestamp'} > $graphiteMaxTime and
            $perfData{$fields[1]}->{'timestamp'} > $today
           )
         {
            my $i=2;
            while(defined($fields[$i]))
            {
               $perfData{$fields[1]}->{$fields[0]}->{$descriptors{$fields[0]}->{'headings'}[$i-2]} = $fields[$i];
               $i++;
            }
         }
      }
   } 
}
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

#---------------------------------------------------------------------------------------------------
# In nmon terms a snapshot is a point in time look at the system. Go through each snapshot and
# send the data to graphite/whisper 
#---------------------------------------------------------------------------------------------------
my $graphiteData='';
foreach my $snapshot (sort(keys(%perfData)))
{
   #================================================================================================================
   # Initialize top level graphite nodes
   #================================================================================================================
   my $timeStamp = $perfData{$snapshot}->{'timestamp'};
    
   #print "$snapshot\n";
   my $metricType='';

   foreach my $metric (sort(keys(%{$perfData{$snapshot}})))
   {
      #print "\t$metric\n";
      
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
            #print "\t\t$item:\t".$perfData{$snapshot}->{$metric}->{$item}."\n";
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
               }
               else
               {
                  print "NOT NUMERIC: Snapshot: $snapshot, Metric: $metric, Item: [$item]\n";
               }
            }
         }
      }
   }
}
#print "\n$graphiteData\n";
#---------------------------------------------------------------------------------------------------
# Setup for connection to Graphite service send the data and close conection
#---------------------------------------------------------------------------------------------------

my $graphite = IO::Socket::INET->new(PeerAddr   =>   $graphiteHost,
                                     PeerPort   =>   $graphiteWritePort,
                                     Proto      =>   'tcp'
                                    );
$graphite or die("Can't connect to $graphiteHost:$graphiteWritePort");
$graphite->autoflush(1);
   
$graphite->send($graphiteData);
$graphite->shutdown(1);
close $graphite;

#---------------------------------------------------------------------------------------------------
# Query the graphite databse and see what the latest data point is so that we don't repeat data
# in the database
#---------------------------------------------------------------------------------------------------
sub graphiteLastTimeStamp()
{
   my $url      = "$graphiteProt://$graphiteHost:$graphiteReadPort/render?target=$graphitePrefix.ostype.$hosttype.hostname.$hostname.cpu.CPU_ALL.*&format=json&from=$fromDateTime";
   my $response = $ua->post($url, "Content-Type"=>"application/json");
   my $maxAge   = time-(300*24*60*60); # set max age to sometime far in the past (300 days)
   
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
         }
      }
   }
   return $maxAge;
}
