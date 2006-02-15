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

package Tasklist;
use strict;

use vars qw(@ISA);

use constant VERSION		=> "0.6";

# M�dulos que usaremos localmente
use Fcntl qw(SEEK_SET SEEK_END);

# Acesso ao database compat�vel
use TieFighter;

# Construtor para a classe
sub new {
   my ($class, $visits, $filename) = @_;
   my %init;
   my $self = bless { %init }, $class;

   # Refer�ncia para a inst�ncia de Visits
   $self->{visits} = $visits;

   # Esse � o arquivo principal, o de tarefas
   $self->{listfile} = $filename . '.lst';

   # Arquivo que guarda posi��o no arquivo principal
   $self->{posfile} = $filename . '.pos';

   # Abre para leitura E escrita
   open ($self->{handle},
         '+' . ((-s $self->{listfile}) ? '<' : '>'),	# lesado ;)
         $self->{listfile})
      or die "can't open() '$self->{listfile}': $!\n";

   my $h = $self->{handle};

   # TODO: implementar o segundo arquivo, .pos, que salva
   # a atual posi��o e o n�mero de registros no arquivo .lst!
   # E, pior: implementar o retorno a partir desse arquivo...

   # Contadores (defaults)
   $self->{entries}	= 0;	# quantos registros h� no tasklist
				# (WARN: no m�nimo, 1 URL!!!)
   $self->{index}	= 0;	# o registro atual
   $self->{position}	= 0;	# offset do registro atual no arquivo

   # Conta as entries do tasklist
   $self->scan_tasklist;

   # Resume a opera��o, se necess�rio
   if (open (POS, $self->{posfile})) {
      # L� onde foi a "�ltima parada"
      my @pos = ();
      for (my $i = 0; $i < 2; $i++) {
         my $line = <POS>;
         chomp $line;
         next unless $line =~ /^\d+$/;
         push @pos, $line;
      }
      close POS;

      # Devemos ter apenas 2 n�meros, um por linha, nesse arquivo!
      if ($#pos == 1) {
         $self->{index}		= shift @pos;
         $self->{position}	= shift @pos;

         # Voltar para a �ltima posi��o
         seek ($h, $self->{position}, SEEK_SET);
      }
   }

   return $self;
}

# No momento, apenas conta quantas URLs h� no arquivo de tasklist,
# exibindo o progresso
sub scan_tasklist {
   my $self = shift;
   my $h = $self->{handle};

   # Meio luso... Mas � a forma mais segura de contar!
   # WARN: para arquivos gigantes... Pode demorar MUUUITOOOOO!!!
   my $size = -s $self->{listfile};
   my ($progress, $progress_) = qw(0 0);
   while (<$h>) {
      $progress = sprintf '%0.1f%%', (tell ($h) / $size) * 100.0;

      # Verifica se o indicador de progresso mudou
      # (isso � para n�o imprimi-lo para CADA LINHA LIDA :/
      if ($progress ne $progress_) {
         print "loading tasklist ($progress)\r";
         $progress_ = $progress;
      }

      ++$self->{entries};
   }
   print "\n" x 2;

   # Volta para o come�o do tasklist
   seek ($h, 0, SEEK_SET);

   return;
}

# Indicador de progresso ultra-coxa ;)
# Mostra a rela��o entre a posi��o atual e o n�mero total de entradas no tasklist...
# A primeira impress�o � que h� REGRESSO, pois o tasklist cresce mais r�pido do
# que os probes avan�am por ele... Hummmm, acredito que vai precisar de uns 9 zeros
# ap�s a v�rgula pra crawlar a Internet inteira :/
sub progress {
   my $self = shift;
   my $p = $self->{index} / $self->{entries};
   return sprintf '%0.3f%%', $p * 100.0;
}

# Pega as pr�ximas URLs a serem processadas
sub next {
   my ($self, $n) = @_;
   $n = 1 unless defined $n;
   my $h = $self->{handle};

   my @urls = ();
   while ((scalar @urls < $n) && (my $url = <$h>)) {
      # D� um trim na URL
      chomp $url;
      $url =~ s/^\s+//;
      $url =~ s/\s+$//;
      next unless $url;

      # Salva para retornar
      push @urls, $url;

      # Incrementa o �ndice e atualiza a posi��o no arquivo
      ++$self->{index};
      $self->{position} = tell $h;
   }

   return @urls;
}

# Coloca URLs na fila
sub enqueue {
   my ($self, @urls) = @_;

   # Sim, pode acontecer de recebermos HTML sem um sequer link!
   # N�o vale a pena ir at����� o final do arquivo e voltar por isso...
   return unless @urls;

   my $h = $self->{handle};

   # Onde estamos no momento?
   # WARN: j� temos essa informa��o!
   #my $pos = tell $h;

   # Vamos pro final do arquivo
   seek ($h, 0, SEEK_END);

   # Adicionamos essas URLs (apenas UMA vez!!!)
   foreach my $url (@urls) {
      # WARN: interc�mbio com Visits ocorre aqui
      next if $self->{visits}->is_marked ($url);

      # Registra a URL como agendada para visita
      $self->{visits}->mark ($url);

      # D� um append
      printf $h "%s\n", $url;

      # Incrementa o n�mero de tasks
      ++$self->{entries};
   }

   # Voltar para a posi��o anterior
   seek ($h, $self->{position}, SEEK_SET);

   return 1;
}

# Salva a posi��o atual e o tamanho do tasklist
sub save_state {
   my $self = shift;

   # Sobreescreve o registro anterior
   open (POS, '>' . $self->{posfile})
      or die "can't open() '$self->{posfile}': $!\n";

   # Salva nesta ordem: �ndice/posi��o no arquivo
   print POS $self->{index}, "\n";
   print POS $self->{position}, "\n";

   close POS;

   return 0;
}

# Fecha de forma segura
sub close {
   my $self = shift;

   close $self->{handle};

   return 1;
}

1;
