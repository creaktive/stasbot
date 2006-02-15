#!/usr/bin/perl -w
use strict;
use Fcntl;
use DB_File;

my %db;
my $db = tie (%db,  'DB_File', 'db/stasbot_dir', O_RDONLY, 0600, $DB_BTREE);

my ($k, $v) = qw(0 0);
for (my $s = $db->seq ($k, $v, R_FIRST); $s == 0; $s = $db->seq ($k, $v, R_NEXT)) {
   printf "%12d\t%s\n", $v, $k;
}

undef $db;
untie %db;
exit;
