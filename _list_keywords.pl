#!/usr/bin/perl -w
use strict;
use Fcntl;
use File::Spec::Functions;
use SDBM_File;
use Switch;

my $domain = shift @ARGV;
die "usage: $0 hostname\n" unless $domain;

my @bucket = qw(db keywords);
for (my $i = 1; $i <= 2; $i++) {
   push @bucket, substr ($domain, 0, $i);
}

my %kw = ();
my $kw = tie (%kw, 'SDBM_File', catfile (@bucket, $domain), O_RDONLY, 0600);
die "error: $!\n" unless $kw;

my (%t, %d, %k, %n);
while (my ($key, $value) = each %kw) {
   my $n = unpack 'N', $value;
   switch (substr ($key, 0, 1)) {
      case '#'	{ $t{ substr ($key, 1) } = $n }
      case '$'	{ $d{ substr ($key, 1) } = $n }
      case '%'	{ $k{ substr ($key, 1) } = $n }
      else	{ $n{$key} = $n }
   }
}

undef $kw;
untie %kw;

print "\n * TITLE:\n\n";
print_sorted (\%t);

print "\n * DESCRIPTION:\n\n";
print_sorted (\%d);

print "\n * KEYWORDS:\n\n";
print_sorted (\%k);

print "\n * BODY:\n\n";
print_sorted (\%n);

exit;


sub print_sorted {
   my $h = shift;
   foreach my $keyword (sort { ($$h{$b} <=> $$h{$a}) or ($a cmp $b) } keys %$h) {
      printf "%6d\t%s\n", $$h{$keyword}, $keyword;
   }
}
