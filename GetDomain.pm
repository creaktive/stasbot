#!/usr/bin/perl -w

##############################################################################
#	This file is part of 'stasbot' Web Crawler robot engine.
#	Copyright (C) 2006  Stanislaw Y. Pusep
#
#	This program is free software; you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation; either version 2 of the License, or
#	(at your option) any later version.
#
#	This program is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with this program; if not, write to the Free Software
#	Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
#	E-Mail:	stas@sysd.org
#	Site:	http://sysd.org/
##############################################################################

package GetDomain;
use strict;

use vars qw(@ISA @EXPORT %DPN);

@ISA	= qw(Exporter); 
@EXPORT	= qw(get_domain);

use constant VERSION		=> "0.1";

use constant COUNTRY	=> 'br';
use constant DPN	=> qw(
	adm	adv	agr	am	arq	art	ato
	bio	bmd	cim	cng	cnt	com	coop
	ecn	edu	eng	esp	etc	eti	far
	fm	fnd	fot	fst	g12	ggf	gov
	imb	ind	inf	jor	lel	mat	med
	mil	mus	net	not	ntr	odo	org
	ppg	pro	psc	psi	qsl	rec	slg
	srv	tmp	trd	tur	tv	vet	zlg
);

%DPN = map { $_, 1 } DPN;

sub get_domain {
   my $host = lc shift;
   my @a = split /\./, $host;
   my $l = scalar @a;

   return '' if ($l < 2) or ($a[-1] ne COUNTRY) or (length $a[0] > 63);

   my $n = defined $DPN{$a[-2]} ? 3 : 2;
   return '' if $l < $n;
   my @b = ();
   for (my $i = $l - $n; $i < $l; $i++) {
      return '' unless length $a[$i];
      push @b, $a[$i];
   }

   return join ('.', @b);
}

1;
