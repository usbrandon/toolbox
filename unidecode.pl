#!/usr/bin/perl -T
#
#  Author: Hari Sekhon
#  Date: 2012-04-06 21:01:42 +0100 (Fri, 06 Apr 2012)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#

$DESCRIPTION="Convert UTF to ASCII, works as a standard unix filter program

Known Issues: uses the Text::Unidecode CPAN module, which seems to convert unknown chars to \"a\"";

$VERSION = "0.6.1";

use strict;
use warnings;
use utf8;
#use Data::Dumper;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils;
use Text::Unidecode; # For changing unicode to ascii

my $file;

%options = (
    "f|files=s"     => [ \$file, "File(s) to unidecode, non-option arguments are also counted as files. If no files are given uses standard input stream" ],
);

get_options();

my @files = parse_file_option($file, "args are files");

sub decode ($) {
    my $string = shift;
    chomp $string;
    print unidecode("$string\n");
}

if(@files){
    foreach my $file (@files){
        open(my $fh, $file) or die "Failed to open file '$file': $!\n";
        while(<$fh>){ decode($_) }
    }
} else {
    while(<STDIN>){ decode($_) }
}
