#============================================================= -*-perl-*-
#
# BackupPC::CGI::BrowseJSON package
#
# DESCRIPTION
#
#   This module implements the BrowseJSON action. Same action as Browse
#   but with JSON output.
#
# AUTHOR
#   Benjamin Renard <brenard@easter-eggs.com>
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

package BackupPC::CGI::BrowseJSON;

use strict;
use Encode qw/decode_utf8/;
use BackupPC::CGI::Lib qw(:all);
use BackupPC::View;
use BackupPC::XS qw(:all);
use JSON::XS;

sub ErrorJSON {
    my ( $msg ) = @_;
    my %err;
    $err{-1} = $msg;
    print "Content-type: text/plain\n\n";
    print encode_json(\%err);
    exit();
}

sub action
{
    my $Privileged = CheckPermission($In{host});
    my($i, $attr);

    if ( !$Privileged ) {
        ErrorJSON("Not Allowed");
    }
    my $host  = $In{host};
    my $num   = $In{num};
    my $share = $In{share};
    my $dir   = $In{dir};

    ErrorJSON("You must specify an hostname") if ( $host eq "" );
    #
    # Find the requested backup and the previous filled backup
    #
    my @Backups = $bpc->BackupInfoRead($host);

    # Initialise my return hash
    my %all;

    #
    # default to the newest backup
    #
    if ( !defined($In{num}) && @Backups && @Backups > 0 ) {
        $i = @Backups - 1;
        $num = $Backups[$i]{num};
    }

    for ( $i = 0 ; $i < @Backups ; $i++ ) {
        last if ( $Backups[$i]{num} == $num );
    }
    if ( $i >= @Backups || $num !~ /^\d+$/ ) {
        ErrorJSON("Backup number ${EscHTML($num)} for host ${EscHTML($host)} does"
	        . " not exist.");
    }

    # Store backup num and start time
    $all{backupNum} = $num;
    $all{backupStartTime} = $Backups[$i]{startTime};

    my $view = BackupPC::View->new($bpc, $host, \@Backups, {nlink => 1});

    if ( $dir eq "" || $dir eq "." || $dir eq ".." ) {
	$attr = $view->dirAttrib($num, "", "");
	if ( keys(%$attr) > 0 ) {
	    $share = (sort(keys(%$attr)))[-1];
	    $dir   = '/';
	} else {
            ErrorJSON("Backup number ${EscHTML($num)} for host ${EscHTML($host)} is empty.");
	}
    }
    $dir = "/$dir" if ( $dir !~ /^\// );

    # Store current share and path
    $all{currentShare} = $share;
    $all{currentPath} = $dir;

    my $relDir  = $dir;
    my $currDir = undef;
    if ( $dir =~ m{(^|/)\.\.(/|$)} ) {
        ErrorJSON("Invalid directory parameter");
    }

    # This hash will content current directory content
    my %data;

    # This hash will be used to parse tree
    my %tree;
    my %subTree;

    #
    # Loop up the directory tree until we hit the top.
    #
    while ( 1 ) {
	$attr = $view->dirAttrib($num, $share, $relDir);
        if ( !defined($attr) ) {
            ErrorJSON("Incorrect directory");
        }

        #
        # Loop over each of the files in this directory
        #
	foreach my $f ( sort {uc($a) cmp uc($b)} keys(%$attr) ) {
            my($dirOpen, $path);
	    if ( $relDir eq "" ) {
		$path = "/$f";
	    } else {
		($path = "$relDir/$f") =~ s{//+}{/}g;
	    }
	    if ( $share eq "" ) {
		$path  = "/";
	    }
            $path =~ s{^/+}{/};
            $path     =~ s/([^\w.\/-])/uc sprintf("%%%02X", ord($1))/eg;
            $dirOpen  = 1 if ( defined($currDir) && $f eq $currDir );
            if ( $attr->{$f}{type} == BPC_FTYPE_DIR ) {
                # Add in tree as empty hash (if not already present)
                if (!exists $tree{$f}) {
                    my %fInfos;
                    %{$tree{$f}}=%fInfos;
                }
                # Put path key in tree element infos
                $tree{$f}{path}=$path;
            }
            if ( $relDir eq $dir ) {
                #
                # This is the selected directory, so display all the files
                #
                if ( defined($a = $attr->{$f}) ) {
                    my %infos;
                    $infos{type} = BackupPC::XS::Attrib::fileType2Text($a->{type});
                    $infos{mtime} = $a->{mtime};
                    $infos{mode} = sprintf("0%o", $a->{mode} & 07777);
                    $infos{backupNum} = $a->{backupNum};
                    $infos{size} = $a->{size};
                    $infos{path} = $path;
                    %{$data{$f}} = %infos;
                }
            }
        }

        last if ( $relDir eq "" && $share eq "" );

        # Store current parse tree as currrent dir's sub-tree
        %subTree = %tree;

        # Clear %tree hash
        for (keys %tree) {
            delete $tree{$_};
        }

        # 
        # Prune the last directory off $relDir, or at the very end
	# do the top-level directory.
        #

        # Check is first iteration
        my $first = 1 if (!defined($currDir));

	if ( $relDir eq "" || $relDir eq "/" || $relDir !~ /(.*)\/(.*)/ ) {
	    $currDir = $share;
	    $share = "";
	    $relDir = "";
	} else {
	    $relDir  = $1;
	    $currDir = $2;
	}

        # Store previous parse tree in new tree as current dir content
        %{$tree{$currDir}{content}} = %subTree;

        # Put active flag as 1 if it's current directory (=first iteration)
        $tree{$currDir}{current} = 1 if ($first);
    }

    %{$all{data}} = %data;
    %{$all{tree}} = %tree;
    print "Content-type: text/plain\n\n";
    print encode_json(\%all);
}

1;
