#!/usr/bin/perl -w
use strict;
use Socket;
use TieFighter;

my %db = %{ _tie ('db/stasbot_dns', 0) };

while (my ($key, $val) = each %db) {
   my ($time, $addr) = unpack 'l a*', $val;
   next unless $time;

   my @addr = ();
   for (my $i = 0; $i < length $addr; $i += 4) {
      push @addr, inet_ntoa (substr ($addr, $i, 4));
   }

   printf "[%s] %s {%s}\n", scalar localtime $time, $key, join ('; ', @addr);
}

untie %db;
exit;
