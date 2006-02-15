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

package DNS_Cache;
use strict;

use vars qw(@ISA);

use constant VERSION		=> "0.3";

use constant EXPIRES		=> 12*(60*60);	# 12 horas!

# Módulos que usaremos localmente
use Net::DNS;
use Socket;

# Acesso ao database compatível
use TieFighter;

# Construtor para a classe
sub new {
   my ($class, $dbfile) = @_;
   my %init;
   my $self = bless { %init }, $class;

   # Associa o HASH ao arquivo
   $self->{dbfile} = $dbfile;
   $self->{db} = _tie ($dbfile);

   # Instância do cliente DNS
   $self->{dns} = new Net::DNS::Resolver;

   return $self;
}

# Guarda resultados de um request DNS no cache
sub cache {
   my ($self, $host, @addr) = @_;

   # Converte para formato binário
   my $addr = @addr ? join '', map { inet_aton ($_) } @addr : '';
   ${$self->{db}} {lc $host} = pack 'l a*', time, $addr;

   return 1;
}

# Tira host do cache
sub uncache {
   my ($self, $host) = @_;
   delete ${$self->{db}} {lc $host};
   return 1;
}

# Pesquisa o cache
sub get_cached {
   my ($self, $host) = @_;

   $host = lc $host;					# Padronização dos hostnames
   return '127.0.0.1' if $host eq 'localhost';		# Um caso bem conhecido ;)
   return undef unless defined ${$self->{db}} {$host};	# Não há registros

   # Converte do formato binário
   my ($time, $addr) = unpack 'l a*', ${$self->{db}} {$host};

   # Marcado como "está sendo resolvido no momento"
   return 0 unless $time;

   # A informação está vencida ;)
   return undef if $time + EXPIRES < time;

   # "Desmonta" o array de endereços IP
   my @addr = ();
   my $i;
   for ($i = 0; $i < length $addr; $i += 4) {
      push @addr, inet_ntoa (substr ($addr, $i, 4));
   }

   # Retorna endereço aleatório (tentativa de distribuir melhor os requests)
   return $i ? $addr[rand scalar @addr] : '';
}

# Envia 'DNS query'
sub dns_bgsend {
   my ($self, $host) = @_;

   # Marca esse hostname para que ninguém mais tente resolvê-lo
   ${$self->{db}} {lc $host} = pack 'l', 0;

   # Envia o pacote do query
   return $self->{dns}->bgsend ($host);
}

# Obtém a resposta do servidor DNS
sub dns_bgread {
   my ($self, $host, $sock) = @_;

   # Lê o pacote
   my $packet = $self->{dns}->bgread ($sock);

   # Algo está, definitivamente, errado :P
   return undef if not defined $packet or not $packet;

   # Obtém a lista de IPs para o host da resposta do servidor
   my @addr = ();
   foreach my $answer ($packet->answer) {
      push @addr, $answer->address if $answer->isa ('Net::DNS::RR::A');
   }

   # Guarda resultados no cache
   $self->cache ($host, @addr);

   # Retorna endereço aleatório (tentativa de distribuir melhor os requests)
   return @addr ? $addr[rand scalar @addr] : '';
}

# Desassocia e fecha
sub close {
   my $self = shift;

   untie %{$self->{db}};
   delete $self->{dns};

   return 1;
}

1;
