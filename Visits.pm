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

package Visits;
use strict;

use vars qw(@ISA);

use constant VERSION		=> "0.5";

# Acesso ao database compatível
use TieFighter;

# Construtor para a classe
sub new {
   my ($class, $dbfile) = @_;
   my %init;
   my $self = bless { %init }, $class;

   # Nesse ponto, apenas associamos um HASH com database
   $self->{dbfile} = $dbfile;
   $self->{db} = _tie ($dbfile);

   return $self;
}

# Verifica se já registramos esta URL
sub is_marked {
   my ($self, $url) = @_;
   return defined ${$self->{db}} {$url} ? 1 : 0;
}

# Marca a URL como agendada
sub mark {
   my ($self, $url) = @_;
   ${$self->{db}} {$url} = '';
   return 1;
}

# Grava um 'struct' com dados sobre a página na chave associada à URL
sub record {
   my ($self, $url, $record) = @_;

   # Meio que toscão ;)
   # Já a URL deveria estar limitada em OUTRO lugar!
   # OBS: a princípio, o título da página era para ser guardado *aqui*...
   # Mas agora que salvamos o conteúdo dos HTML em *outro* lugar :/
   my $data = pack (
	'i I',
	${$record} {last_accessed},
	${$record} {received_bytes},
   );

   ${$self->{db}} {$url} = $data;

   return 1;
}

# Desassocia o HASH do arquivo e fecha o mesmo
sub close {
   my $self = shift;
   untie %{$self->{db}};
   return 1;
}

1;
