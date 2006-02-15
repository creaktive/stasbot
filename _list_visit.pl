#!/usr/bin/perl -w
use strict;
use Fcntl;
use DB_File;

my %db;
my $db = tie (%db,  'DB_File', 'db/stasbot_visit', O_RDONLY, 0600, $DB_BTREE);

my ($pages, $total) = qw(0 0);
my $stime = 0x7fffffff;
my $ftime = 0;

my ($k, $v) = qw(0 0);
for (my $s = $db->seq ($k, $v, R_FIRST); $s == 0; $s = $db->seq ($k, $v, R_NEXT)) {
   my $url = $k;
   my $record = $v;
   next unless $record;

   my ($last_accessed, $received_bytes) = unpack 'i I', $record;

   if ($last_accessed < $stime) {
      $stime = $last_accessed;
   } elsif ($last_accessed > $ftime) {
      $ftime = $last_accessed;
   }

   ++$pages;
   $total += $received_bytes;

   printf "[%s]\n\t%s\n\t%d bytes\n\n", $url, scalar localtime $last_accessed, $received_bytes;
}

undef $db;
untie %db;

my $elapsed = $ftime - $stime;
printf STDERR "total pages: %s\n", $pages;
printf STDERR "elapsed min: %d\n", $elapsed / 60;
printf STDERR "total bytes: %0.2f MB\n", $total / (2**20);
printf STDERR " avg. speed: %0.2f KB/s\n", ($total / ($elapsed << 10));
printf STDERR "  avg. size: %0.2f KB/page\n", ($total / ($pages << 10));

exit;
