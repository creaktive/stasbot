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

package Configuration;
use strict;

use vars qw(@ISA @EXPORT);

@ISA	= qw(Exporter); 
@EXPORT	= qw(load_conf);

use constant VERSION		=> "0.6";

# Construtor para a classe
sub new {
   my ($class, $conf) = @_;
   my %init;
   my $self = bless { %init }, $class;

   $self->{conf}	= $conf;

   $self->reload;

   return $self;
}

# Nome que diz tudo :P
sub reload {
   my $self = shift;

   # Carrega o arquivo das configurações
   my @conf = ();
   load_conf ($self->{conf}, sub { push @conf, shift });
   my ($max_probes, $max_dir, @exclusions) = @conf;

   # Limitações do formato
   unless (($max_probes =~ /^\d+$/) and ($max_probes > 0) and ($max_probes < 65535)) {
      die "malformed file '$self->{conf}' (bad MAX_PROBES)\n";
   }
   unless ($max_dir =~ /^\d+$/) {
      die "malformed file '$self->{conf}' (bad MAX_DIR)\n";
   }

   $self->{max_probes}	= $max_probes;

   $main::MAX_DIR = $max_dir;

   delete $self->{exclusions};
   $self->{exclusions}	= [@exclusions];

   return 1;
}

# Carrega o arquivo das configurações
sub load_conf {
   my ($conf, $callback) = @_;
   open (CONF, $conf) or die "can't open '$conf': $!\n";

   my @lines = ();
   while (my $line = <CONF>) {
      chomp $line;
      $line =~ s/#.*$//;	# corta fora os comentários
      $line =~ s/^\s+//;	# e também os espaços no começo
      $line =~ s/\s+$//;	# e no final

      next if $line eq '';

      &{$callback} ($line);
   }
   close CONF;

   return 1;
}

# Método de acesso
sub max_probes {
   return $_[0]->{max_probes};
}

# Método de acesso
sub exclusions {
   return @{$_[0]->{exclusions}};
}

1;
