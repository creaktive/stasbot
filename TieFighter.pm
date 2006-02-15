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

package TieFighter;
use strict;

use vars qw(@ISA @EXPORT $has_DB_File);

@ISA	= qw(Exporter); 
@EXPORT	= qw(_tie _sync);

# Prioridade dos módulos de acesso ao database
BEGIN { @AnyDBM_File::ISA = qw(DB_File SDBM_File) }
use AnyDBM_File;

# Marca a presença do Berkeley DB
$has_DB_File = '';
eval '$has_DB_File=$DB_File::DB_BTREE';

use Fcntl;

sub _tie {
   my ($dbfile, $force) = @_;

   my $flags	= defined $force ? $force : O_CREAT | O_RDWR;
   my $mode	= 0600;
   my @btree	= ();

   # Se temos DB_File, usamos o modo B-tree dele!
   push @btree, $has_DB_File if $has_DB_File;

   my %db;
   my $ref = tie (%db, 'AnyDBM_File', $dbfile, $flags, $mode, @btree);
   die "can't tie() '$dbfile': $!\n" unless $ref;

   return \%db;
}

sub _sync {
   return 0 unless $has_DB_File;

   my $db = shift;
   my $ref = tied %{$db};
   $ref->sync;
   undef $ref;

   return 1;
}

1;
