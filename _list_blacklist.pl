#!/usr/bin/perl -w
use strict;
use TieFighter;

my %db = %{ _tie ('db/stasbot_blacklist', 0) };

while (my ($key, $count) = each %db) {
   printf "%4d\t%s\n", $count, $key;
}

untie %db;
exit;
