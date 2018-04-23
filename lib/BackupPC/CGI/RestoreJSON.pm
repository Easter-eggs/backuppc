#============================================================= -*-perl-*-
#
# BackupPC::CGI::Restore package
#
# DESCRIPTION
#
#   This module implements the Restore action for the CGI interface.
#
# AUTHOR
#   Craig Barratt  <cbarratt@users.sourceforge.net>
#
# COPYRIGHT
#   Copyright (C) 2003-2009  Craig Barratt
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#========================================================================
#
# Version 3.2.1, released 24 Apr 2011.
#
# See http://backuppc.sourceforge.net.
#
#========================================================================

package BackupPC::CGI::RestoreJSON;

use strict;
use BackupPC::CGI::Lib qw(:all);
use BackupPC::Xfer;
use Data::Dumper;
use File::Path;
use Encode qw/decode_utf8/;
use JSON;

sub ErrorJSON {
    my ( $msg ) = @_;
    my %err;
    $err{-1} = $msg;
    print "Content-type: text/plain\n\n";
    print to_json(\%err);
    exit();
}


sub action
{

    my($str, $reply, $content);
    my $Privileged = CheckPermission($In{host});
    if ( !$Privileged ) {
        ErrorJSON("You can't download backup from this host");
    }
    my $host  = $In{host};
    my $num   = $In{num};
    my $share = $In{share};
    my(@fileList, $fileListStr, $hiddenStr, $pathHdr, $badFileCnt);
    my @Backups = $bpc->BackupInfoRead($host);

    ServerConnect();
    if ( !defined($Hosts->{$host}) ) {
        ErrorJSON("Incorrect hostname");
    }

    my $paths = decode_json($In{paths});
    foreach my $path ( @$paths ) {
        (my $name = $path) =~ s/%([0-9A-F]{2})/chr(hex($1))/eg;
        $badFileCnt++ if ( $name =~ m{(^|/)\.\.(/|$)} );
	if ( @fileList == 0 ) {
	    $pathHdr = substr($name, 0, rindex($name, "/"));
	} else {
	    while ( substr($name, 0, length($pathHdr)) ne $pathHdr ) {
		$pathHdr = substr($pathHdr, 0, rindex($pathHdr, "/"));
	    }
	}
        push(@fileList, $name);
        $name = decode_utf8($name);
    }
    $badFileCnt++ if ( $In{pathHdr} =~ m{(^|/)\.\.(/|$)} );
    $badFileCnt++ if ( $In{num} =~ m{(^|/)\.\.(/|$)} );
    if ( @fileList == 0 ) {
        ErrorJSON("No file paths specify");
    }
    if ( $badFileCnt ) {
        ErrorJSON("Invalid parameters");
    }
    $pathHdr = "/" if ( $pathHdr eq "" );
    if ( $In{type} == 1 ) {
        #
        # Provide the selected files via a tar archive.
	#
	my @fileListTrim = @fileList;
	if ( @fileListTrim > 10 ) {
	    @fileListTrim = (@fileListTrim[0..9], '...');
	}
	$bpc->ServerMesg("log User $User downloaded tar archive for $host,"
		       . " backup $num; files were: "
		       . join(", ", @fileListTrim));

        my @pathOpts;
        if ( $In{relative} ) {
            @pathOpts = ("-r", $pathHdr, "-p", "");
        }
	print(STDOUT <<EOF);
Content-Type: application/x-gtar
Content-Transfer-Encoding: binary
Content-Disposition: attachment; filename=\"restore.tar\"

EOF
	#
	# Fork the child off and manually copy the output to our stdout.
	# This is necessary to ensure the output gets to the correct place
	# under mod_perl.
	#
	$bpc->cmdSystemOrEvalLong(["$BinDir/BackupPC_tarCreate",
		 "-h", $host,
		 "-n", $num,
		 "-s", $share,
		 @pathOpts,
		 @fileList
	    ],
	    sub { print(@_); },
	    1,			# ignore stderr
	);
    } elsif ( $In{type} == 2 ) {
        #
        # Provide the selected files via a zip archive.
	#
	my @fileListTrim = @fileList;
	if ( @fileListTrim > 10 ) {
	    @fileListTrim = (@fileListTrim[0..9], '...');
	}
	$bpc->ServerMesg("log User $User downloaded zip archive for $host,"
		       . " backup $num; files were: "
		       . join(", ", @fileListTrim));

        my @pathOpts;
        if ( $In{relative} ) {
            @pathOpts = ("-r", $pathHdr, "-p", "");
        }
	print(STDOUT <<EOF);
Content-Type: application/zip
Content-Transfer-Encoding: binary
Content-Disposition: attachment; filename=\"restore.zip\"

EOF
	$In{compressLevel} = 5 if ( $In{compressLevel} !~ /^\d+$/ );
	#
	# Fork the child off and manually copy the output to our stdout.
	# This is necessary to ensure the output gets to the correct place
	# under mod_perl.
	#
	$bpc->cmdSystemOrEvalLong(["$BinDir/BackupPC_zipCreate",
		 "-h", $host,
		 "-n", $num,
		 "-c", $In{compressLevel},
		 "-s", $share,
		 @pathOpts,
		 @fileList
	    ],
	    sub { print(@_); },
	    1,			# ignore stderr
	);
    } elsif ( $In{type} == 4 ) {
	if ( !defined($Hosts->{$In{hostDest}}) ) {
	    ErrorJSON("This host doesn't exists");
	}
	if ( !CheckPermission($In{hostDest}) ) {
	    ErrorJSON("You don't have permission to restore on this host.");
	}
	my $hostDest = $1 if ( $In{hostDest} =~ /(.+)/ );
	my $ipAddr = ConfirmIPAddress($hostDest);
        #
        # Prepare and send the restore request.  We write the request
        # information using Data::Dumper to a unique file,
        # $TopDir/pc/$hostDest/restoreReq.$$.n.  We use a file
        # in case the list of files to restore is very long.
        #
        my $reqFileName;
        for ( my $i = 0 ; ; $i++ ) {
            $reqFileName = "restoreReq.$$.$i";
            last if ( !-f "$TopDir/pc/$hostDest/$reqFileName" );
        }
	my $inPathHdr = $In{pathHdr};
	$inPathHdr = "/$inPathHdr" if ( $inPathHdr !~ m{^/} );
	$inPathHdr = "$inPathHdr/" if ( $inPathHdr !~ m{/$} );
        my %restoreReq = (
	    # source of restore is hostSrc, #num, path shareSrc/pathHdrSrc
            num         => $In{num},
            hostSrc     => $host,
            shareSrc    => $share,
            pathHdrSrc  => $pathHdr,

	    # destination of restore is hostDest:shareDest/pathHdrDest
            hostDest    => $hostDest,
            shareDest   => $In{shareDest},
            pathHdrDest => $inPathHdr,

	    # list of files to restore
            fileList    => \@fileList,

	    # other info
            user        => $User,
            reqTime     => time,
        );
        my($dump) = Data::Dumper->new(
                         [  \%restoreReq],
                         [qw(*RestoreReq)]);
        $dump->Indent(1);
        eval { mkpath("$TopDir/pc/$hostDest", 0, 0777) }
                                    if ( !-d "$TopDir/pc/$hostDest" );
	my $openPath = "$TopDir/pc/$hostDest/$reqFileName";
        if ( open(REQ, ">", $openPath) ) {
	    binmode(REQ);
            print(REQ $dump->Dump);
            close(REQ);
        } else {
            ErrorJSON(eval("qq{$Lang->{Can_t_open_create__openPath}}"));
        }
	$reply = $bpc->ServerMesg("restore ${EscURI($ipAddr)}"
			. " ${EscURI($hostDest)} $User $reqFileName");
        print "Content-type: text/plain\n\n";
        print to_json($reply);
        exit();
    }
}

1;
