package BackupPC::CGI::Stats;

use strict;
use BackupPC::Lib;
use BackupPC::XS qw(:all);
use BackupPC::CGI::Lib qw(:all);
use BackupPC::View;
use Encode qw/decode_utf8/;
use JSON::XS;

sub action
{

    my %stats;
    my %temp;
    my %config;
    my %all;
    my %detailled;

    my $server = BackupPC::Lib->new();

    my $mainConf = $bpc->ConfigDataRead();
    my $hostinfo = $server->HostInfoRead();
    foreach my $host ( keys %$hostinfo ) {
        my @backups = $server->BackupInfoRead($host);


        # Retrieve host config
        my $conf = $server->ConfigDataRead($host);
        $conf = { %$mainConf, %$conf };
        $config{$host}{XferMethod} = $conf->{XferMethod};
        $config{$host}{FullPeriod} = $conf->{FullPeriod};
        $config{$host}{FullKeepCnt} = $conf->{FullKeepCnt};
        $config{$host}{IncrPeriod} = $conf->{IncrPeriod};
        $config{$host}{IncrKeepCnt} = $conf->{IncrKeepCnt};
        $config{$host}{BackupsDisable} = $conf->{BackupsDisable};
        $config{$host}{BackupFilesExclude} =  $conf->{BackupFilesExclude}{'*'};
        $config{$host}{BlackoutPeriods} =  $conf->{BlackoutPeriods};
        $config{$host}{CompressLevel} =  $conf->{CompressLevel};

        foreach my $bkp ( @backups ) {
            $temp{$host}{backup}[$bkp->{num}] = $bkp;
            # Create new hash with all host's backups
            $detailled{$host}{$bkp->{num}} = $bkp;
            # Add key state = 1 for all backups
            $detailled{$host}{$bkp->{num}}{state} ++;

            # Count number of backups
            $temp{$host}{count}++;
            $temp{$host}{fullcount} ++ if ( $bkp->{type} eq 'full' );
            $temp{$host}{incrcount} ++ if ( $bkp->{type} eq 'incr' );

            # SIZE
            # size = sizeNew + sizeExist
            if ( $temp{$host}{totalsize} == 0 ) {
                $temp{$host}{totalsize} += $bkp->{sizeExistComp};
                $temp{$host}{totalsize} += $bkp->{sizeNewComp};
            } else {
                $temp{$host}{totalsize} += $bkp->{sizeNewComp};
            }
            my $sizeMo = $bkp->{size} / 1024 / 1024;
            my $sizeNewMo = $bkp->{sizeNew} / 1024 / 1024;

            # DURATION
            my $duration = $bkp->{endTime} - $bkp->{startTime};
            $temp{$host}{duration}{$bkp->{type}} += $duration;
            $detailled{$host}{$bkp->{num}}{Duration} = $duration;

            #SPEED
	    my $speed;
	    if ( $duration != 0){
	            $speed = $sizeNewMo / $duration;
        	    $temp{$host}{speed}{$bkp->{type}} += $speed;
	            $detailled{$host}{$bkp->{num}}{Speed} =  sprintf "%.2f", $detailled{$host}{$bkp->{num}}{sizeNew} /1024 / 1024 / $duration;
            } else {
                    $speed = 0;
		    $detailled{$host}{$bkp->{num}}{Speed} = 0;
            }

            #COMRESSION percent
            my $compNew;
            my $compExist;
            if ( $bkp->{sizeNew} != 0 ) {
                $compNew = ( $bkp->{sizeNewComp} * 100 ) / $bkp->{sizeNew};
                $detailled{$host}{$bkp->{num}}{compnewrate} = sprintf "%.2f", 100 - $compNew;
            }
            if ( $bkp->{sizeExist} != 0 ) {
                $compExist = ( $bkp->{sizeExistComp} * 100 ) / $bkp->{sizeExist};
                $detailled{$host}{$bkp->{num}}{compexistrate} = sprintf "%.2f", 100 - $compExist;
            }
#            $detailled{$host}{$bkp->{num}}{Compression} = sprintf "%.2f", 100 - ( $detailled{$host}{$bkp->{num}}{sizeNewComp} * 100 / $detailled{$host}{$bkp->{num}}{sizeNew} ) unless  ( $detailled{$host}{$bkp->{num}}{sizeNew} == 0 );

            $temp{$host}{nFiles}{$bkp->{type}} += $bkp->{nFiles};

        }
    }
    foreach my $host ( sort keys %temp ) {
        my %hash = %{$temp{$host}};

        $stats{$host}{count} = $hash{count};

        # SIZE ( GB )
        my $totalsize = sprintf( "%.2f", $hash{totalsize} / 1024 / 1024 / 1024 );
        $stats{$host}{size} = $totalsize;

        # DURATION average ( min )
        my $fullduration_average = sprintf( "%.2f", $hash{duration}{full} / $hash{fullcount} / 60 ) unless ( $hash{fullcount} == 0 );
        my $incrduration_average = sprintf( "%.2f", $hash{duration}{incr} / $hash{incrcount} / 60 ) unless ( $hash{incrcount} == 0 );
        $stats{$host}{duration_full} = $fullduration_average;
        $stats{$host}{duration_incr} = $incrduration_average;

        # SPEED ( MB/s )
        my $fullspeed_average = sprintf( "%.2f", $hash{speed}{full} / $hash{fullcount} ) unless ( $hash{fullcount} == 0 );
        my $incrspeed_average = sprintf( "%.2f", $hash{speed}{incr} / $hash{incrcount} ) unless ( $hash{incrcount} == 0 );
        $stats{$host}{speed_full} = $fullspeed_average;
        $stats{$host}{speed_incr} = $incrspeed_average;

        $stats{$host}{files_full} = $hash{nFiles}{full};
        $stats{$host}{files_incr} = $hash{nFiles}{incr};

    }

    # Setup json data
    %{$all{global}} = %stats;
    %{$all{config}} = %config;
    %{$all{backups}} = %detailled;


    # Print data
    print "Content-type: application/json; charset=utf-8\n\n";
    print encode_json(\%all);
    print "\n";
    return;

}

1;
