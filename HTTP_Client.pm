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

package HTTP_Client;
use strict;

use vars qw(@ISA @EXPORT $recv);

# Exporta essas funções absurdas de complexas :P
@ISA	= qw(Exporter); 
@EXPORT	= qw(host_is_IP host_port);

use constant VERSION		=> "0.99";

# Zera o contador
$recv = 0;

# Coisas que geralmente marcam final da linha
use constant CR			=> "\015";
use constant LF			=> "\012";
use constant CRLF		=> CR . LF;

# Parâmetros da conexão
use constant TIMEOUT		=> 20.0;	# o maior tempo tolerável para a inatividade na conexão
use constant DNS_TIMEOUT	=> 60.0;	# timeout para respostas do servidor DNS
						# WARN: Coisas Ruins poderão acontecer se DNS_TIMEOUT >= TIMEOUT!!!
use constant SELECT_TIMEOUT	=> 0.0;
use constant RECV_BUFFER_LENGTH	=> 8192;	# recebe pacotes de 8 KB (a média ponderada é 10 KB/página)
use constant MAX_LENGTH		=> 128*1024;	# 128 KB é o maior HTML que iremos encarar...

# Parâmetros do protocolo HTTP
use constant HTTP_SUCCESS	=> qw(200 301 302);	# códigos HTTP indicando que o servidor está feliz
use constant ALLOWED_TYPES	=> qw(text/html);	# somente processamos HTML

# Módulos que usaremos localmente
use Fcntl;
use IO::Socket;
use Time::HiRes qw(gettimeofday tv_interval usleep);	# exagero? nem tanto... time() fará probes 'mortos'
							# se acumularem para serem descontinuados de uma vez,
							# a cada segundo.
use URI;

# Construtor para a classe
sub new {
   my ($class, $url, $agent, $dns_cache, $referrer) = @_;
   my %init;
   my $self = bless { %init }, $class;

   # Desmonta a URL do jeito mais seguro
   my $uri = new URI ($url);

   # Isso é um cliente HTTP, até pelo nome :P
   my $scheme = $uri->scheme;
   return 0 if not defined $scheme or $scheme ne 'http';

   # Ainda não sabemos usar username:password!
   return 0 if $uri->userinfo;

   # Salva para a posterioridade
   $self->{url}		= $url;		# inútil, mas quem sabe serve para algo...
   $self->{uri}		= $uri;		# referência para a instância URI

   # Inicializa acumuladores e contadores
   $self->{data}	= '';
   $self->{data_length}	= 0;
   $self->{headers_end}	= 0;
   $self->{content_start} = 0;

   # Flag indicando o '/robots.txt'
   $self->{robots} = $self->URI->path eq '/robots.txt' ? 1 : 0;

   # Nome do nosso crawler ;)
   $self->{agent} = (defined $agent) ? $agent : '';

   # Sem aplicação, no momento
   $self->{referrer} = (defined $referrer) ? $referrer : '';

   # A instância do cache de DNS
   $self->{dns_cache}	= $dns_cache;
   $self->{addr}	= host_is_IP ($uri->host) ? $uri->host : '';

   # Início da atividade
   $self->update;

   return $self;
}

# Retorna a instância URI associada
sub URI {
   return $_[0]->{uri};
}

# Verifica se este é o 'robots.txt'
sub is_robots {
   return $_[0]->{robots};
}

# Retorna/modifica a identificação do agente HTTP
sub agent {
   my ($self, $agent) = @_;
   $self->{agent} = $agent if defined $agent;
   return $self->{agent};
}

# Resolve o endereço IP via DNS
sub got_address {
   my $self = shift;

   if ($self->{addr}) {
      # Hostname é o próprio endereço IP
      return 1;
   } else {
      my $host = $self->URI->host;

      # Verifica se já foi feito DNS query nesse probe
      unless (defined $self->{dns_sock}) {
         # Ainda não; verifica no cache
         my $addr = $self->{dns_cache}->get_cached ($host);

         if (defined $addr) {
            # Há alguma coisa no cache!

            if ($addr) {
               # É o endereço!
               $self->{addr} = $addr;
               return 1;
            } else {
               # Se $addr == 0, *ainda* não está no cache, mas outro probe já está encarregado!
               unless ($addr eq '0') {
                  # Está marcado como impossível de resolver...
                  ++$self->{force_timeout};
               }
            }

            return 0;
         }

         # Nada no cache; vamos trabalhar!
         my $sock = $self->{dns_cache}->dns_bgsend ($host);

         # Conseguiu enviar?
         if (defined $sock and $sock) {
            # Sim; salva o socket do DNS
            $self->{dns_sock} = $sock;

            # Há atividade nesse probe.
            # OBS: timeout do DNS é menor do que HTTP!
            # WARN: se o servidor DNS não responder, o probe entra em loop infinito
            # e só sai dele quando o servidor responde! Me parece razoável, anyway...
            $self->update;
         } else {
            # Se não, provavelmente o servidor de DNS está morto...
            # Aí, tentamos outra vez!

            # WARN: pode ocorrer um violentíssimo flood de 'DNS query' aqui!!!
            $self->dns_reset ($host);
            print STDERR " * Failed sending DNS query: $!\n";
         }

         return 0;
      } else {
         if (_select_socket ($self->{dns_sock}, 2)) {
            # Falha na comunicação
            $self->dns_reset ($host);
            print STDERR " * Failed receiving DNS answer: $!\n";
            return 0;
         } elsif (_select_socket ($self->{dns_sock}, 0)) {
            # Há uma resposta do servidor aguardando?
            my $addr = $self->{dns_cache}->dns_bgread ($host, $self->{dns_sock});

            # Fecha e desativa o socket
            close $self->{dns_sock};
            delete $self->{dns_sock};

            # Outra falha na comunicação... Maldito UDP!
            unless (defined $addr) {
               $self->dns_reset ($host);
               print STDERR " * Failed processing DNS answer: $!\n";
               return 0;
            }

            unless ($addr) {
               # Hostname inexistente
               ++$self->{force_timeout};
               return 0;
            }

            # Hostname resolvido!!!
            $self->{addr} = $addr;
            return 1;
         } elsif (tv_interval ($self->{last_activity}, [gettimeofday]) > DNS_TIMEOUT) {
            # Servidor DNS não responde!
            # Vamos mandar outro query para ele...
            $self->dns_reset ($host);
            print STDERR " * DNS server timed out: $!\n";
            return 0;
         }
      }
   }

   return 0;
}

# Reinicia o cliente DNS para efetuar mais um query
sub dns_reset {
   my ($self, $host) = @_;
   delete $self->{dns_sock};
   $self->{dns_cache}->uncache ($host);
   usleep (100_000);	# Delay de 1/10 de segundo, pra não f!@#$ com o uso da CPU
   return 1;
}

# Indica que o cliente HTTP está operando
# OBS: *não* está operando quando resolve DNS!
sub is_started {
   return defined $_[0]->{sock};
}

# Inicializa o socket
# OBS: presume que o endereço IP já esteja resolvido e guardado em $self->{addr}!
sub start {
   my $self = shift;

   # Cria o socket para endereço/porta especificados
   my $sock = _make_nb_socket ($self->{addr}, $self->URI->port);
   return 0 unless $sock;

   # Salva o socket
   $self->{sock} = $sock;

   # Sim, está vivo!
   $self->update;

   return 1;
}

# Inicializa o socket; parte "low level"
sub _make_nb_socket {
   my ($addr, $port) = @_;
   my $proto = getprotobyname ('tcp');

   # Cria o socket
   my $sock;
   socket ($sock, PF_INET, SOCK_STREAM, $proto) or return 0;

   # Define parâmetros do socket
   binmode $sock;
   $sock->autoflush (1);
   _stop_blocking ($sock);

   # Associa o socket
   my $inet_addr = inet_aton ($addr);
   my $sin = sockaddr_in ($port, $inet_addr);

   # WARN: Somente inicializa aqui!
   # Não é possível verificar se o connect() sucedeu...
   # Isso será feito pelo mecanismo de timeout/exceptions.
   connect ($sock, $sin);

   return $sock;
}

# Inicializa o socket; parte "VERY low level".
# TODO: testar se funciona para FreeBSD (deveria)!
# Portable turn-off-blocking code, stolen from POE::Wheel::SocketFactory.
sub _stop_blocking {
   my $socket_handle = shift;

   # Do it the Win32 way.
   if ($^O eq 'MSWin32') {
      my $set_it = "1";
      # 126 is FIONBIO (some docs say 0x7F << 16)
      # (0x5421 on my Linux 2.4.25 ?!)
      ioctl ($socket_handle,
             0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
             $set_it) or die "can't ioctl(): $!\n";
   }

   # Do it the way everyone else does.
   else {
      my $flags = fcntl ($socket_handle, F_GETFL, 0) or die "can't getfl(): $!\n";
      $flags = fcntl ($socket_handle, F_SETFL, $flags | O_NONBLOCK) or die "can't setfl(): $!\n";
   }
}

# Indica quando o trabalho desse probe terminou
sub has_finished {
   return $_[0]->{received};
}

# Verifica se podemos dar um send() no socket do probe
# OBS: também verifica a condição se de fato PRECISA dar send()
sub is_writable {
   my $self = shift;
   return (not defined $self->{wrote} and _select_socket ($self->{sock}, 1)) ? 1 : 0;
}

# Verifica se podemos dar um recv() no socket do probe
# OBS: também verifica a condição se de fato PRECISA dar recv()
# OBS: uma das condições é regida pelo limitador de taxa da transferência!
sub is_readable {
   my $self = shift;

   # Verifica flag de término
   return 1 if defined $self->{received};

   # Não há nada no socket
   return 0 unless _select_socket ($self->{sock}, 0);

   # Nesse ponto, sabemos que EXISTE um pacote no socket, esperando!
   return 1;
}

# Verifica se há algo errado com a conexão
sub exception {
   return _select_socket ($_[0]->{sock}, 2);
}

# Verifica a condição do socket (readable/writable/exception), parte "low level".
# Não gosto muito do IO::Select, por ele não ser projetado para operar em sockets *individuais*
sub _select_socket {
   my ($sock, $rwe) = @_;

   my ($rin, $rout);
   $rin = '';

   vec ($rin, fileno ($sock), 1) = 1;

   # TODO:
   #  - descobrir o que significa $rout=$rin como parâmetro do select()
   #  - testar com SELECT_TIMEOUT = 0
   # Não é importante, desde que funcione...
   my $flag = 0;
   if ($rwe == 0) {
      # is readable?
      ++$flag if select ($rout=$rin, undef, undef, SELECT_TIMEOUT);
   } elsif ($rwe == 1) {
      # is writable?
      ++$flag if select (undef, $rout=$rin, undef, SELECT_TIMEOUT);
   } elsif ($rwe == 2) {
      # has exception?
      ++$flag if select (undef, undef, $rout=$rin, SELECT_TIMEOUT);
   }

   return $flag;
}

# Verifica a condição de timeout
sub timed_out {
   my $self = shift;
   return (defined $self->{force_timeout}) or (tv_interval ($self->{last_activity}, [gettimeofday]) > TIMEOUT) ? 1 : 0;
}

# Atualiza o registro da atividade do probe
sub update {
   $_[0]->{last_activity} = [gettimeofday];
   return 1;
}

# Envia o request HTTP
sub send {
   my $self = shift;

   # Forma o pacote de request
   my $request =
      sprintf 'GET %s HTTP/1.0' . CRLF .
              'Host: %s' . CRLF .
              'User-Agent: %s/%s (Perl %vd; %s)' . CRLF,
      $self->URI->path_query, $self->URI->host, $self->agent, VERSION, $^V, $^O;

   # Como já disse, sem utilidade no momento
   if ($self->{referrer}) {
      $request .= sprintf 'Referer: %s' . CRLF, $self->{referrer};
   }

   # Request termina com 2 CRLF seguidos!
   $request .= CRLF;

   # Envia o pacote
   my $r = syswrite ($self->{sock}, $request);
   # Indica que há atividade na conexão
   $self->update;

   # Falhou...
   return 0 if not defined $r or $r == 0;

   # Marca que o send() foi sucedido
   $self->{wrote} = $r;
   return $r;
}

# Recebe a resposta do servidor
# OBS: essa é a parte mais responsável e confusa do cliente :P
sub recv {
   my $self = shift;

   # Recebe dados do socket
   my $buf;
   my $r = sysread ($self->{sock}, $buf, RECV_BUFFER_LENGTH);

   # Verifica o provavel erro
   unless (defined $r) {
      # A coisa tá feia!
      $self->{error} = 'socket error';
      return 0;
   } elsif ($r == 0) {
      # Sem mais a receber; término!
      $self->{received} = 1;
      return -1;
   }

   # Indica que há atividade na conexão
   $self->update;


   # Grava dados recebidos
   $self->{data}	.= $buf;
   $self->{data_length}	+= $r;

   # Atualiza o contador geral de bytes recebidos
   $recv += $r;

   # Cancela download de páginas gigantes (porém processa o que já foi pego!)
   if ($self->{data_length} > MAX_LENGTH) {
      $self->{received} = 1;
      return -1;
   }

   # Processa headers
   unless ($self->{content_start}) {
      # Headers inteiros devem estar no 1-o pacote recebido...
      # Senão, ignoramos o server louco (já que juntar pacotes
      # p/formar headers é uma tarefa complexa demais (pensou
      # se um CRLF está no final do 1-o pacote, e o outro no começo
      # do 2-o?!))

      my $pos;
      $pos = index ($self->{data}, CRLF x 2, 0);
      $pos = index ($self->{data}, LF x 2, 0) if $pos == -1;

      # 15 é o tamanho mínimo de um 'OK' :P
      if ($pos < 15) {
         $self->{error} = 'invalid HTTP answer';
         return 0;
      }

      $self->{headers_end} = $pos;	# headers terminam aqui

      # Localiza o começo do conteúdo
      # (entre headers e content podem existir espaços em branco)
      for (my $i = $pos; $i < $self->{data_length}; $i++) {
         unless (substr ($self->{data}, $i, 1) =~ /\s/) {
            $self->{content_start} = $i;
            last;
         }
      }
      # WARN: content_start ainda PODE ser == 0; para redirecionadores por exemplo!

      # Processa os headers
      my @r = _parse_headers (substr ($self->{data}, 0, $self->{headers_end}));
      unless (@r) {
         $self->{error} = 'no headers';
         return 0;
      }

      # Guarda as informações processadas
      $self->{status} = shift @r;
      $self->{headers} = shift @r;

      # Verifica se o código HTTP indica "tudo OK"
      my $code = ${$self->{status}}[1];
      unless (grep { $code == $_ } HTTP_SUCCESS) {
         $self->{error} = "{WARN} page unavailable (HTTP error code $code)";
         return 0;
      }

      # Redirecionador; terminamos por aqui
      # (e postriormente agendamos o link redirecionado para visita)
      if (($code == 301) or ($code == 302)) {
         $self->{received} = 1;
         return -1;
      }

      # Verifica o tamanho da página pelo tag Content-Length...
      # Ajuda bastante nos servers que suportarem esse tag!
      my $content_length = $self->header ('Content-Length');
      if (($content_length =~ /^\d+$/) and $content_length > MAX_LENGTH) {
         $self->{error} = '{WARN} Content-Length exceeding MAX_LENGTH';
         return 0;
      }

      # Verifica pelo tag Content-Type do header se a página é
      # relevante para um crawler.
      # Não devemos desperdiçar tempo/bandwidth para downloads inúteis :P
      my $content_type = $self->header ('Content-Type');
      $content_type =~ s/[;\s].*$//;	# Corta fora a informação dos encodings


      # 'robots.txt' é um caso especial!
      unless ($self->{robots} and $content_type eq 'text/plain') {
         # filtro por tipo
         unless (grep { $content_type eq $_ } ALLOWED_TYPES) {
            $self->{error} = '{WARN} non-text Content-Type';
            return 0;
         }
      }
   }

   return $r;
}

# Separa o conteúdo da mensagem HTTP recebida
sub content {
   my $self = shift;
   return substr ($self->{data}, $self->{content_start});
}

# Tamanho do conteúdo
sub size {
   my $self = shift;
   return $self->{data_length} - $self->{content_start};
}

# Acesso aos valores definidos nos headers HTTP
sub header {
   my ($self, $header) = @_;
   my $a = ${$self->{headers}} {lc $header};	# 'lowercase' para assegurar a compatibilidade
   return defined $a ? $a : '';
}

# Processa os headers, "low level"
sub _parse_headers {
   # Separa as linhas
   my @headers = split /\015?\012/, shift;

   # 1-a linha é o status HTTP
   my $status = shift @headers;
   my @status = ($status =~ m%^HTTP/(1\.[01])\s+(\d+)\s+(.+)$%i);
   return () unless @status;

   # Guarda key/value dos headers num HASH
   my %headers = ();
   foreach my $line (@headers) {
      next unless $line =~ /^([\w\d\-]+?)\s*:\s*(.+)$/;
      $headers{lc $1} = $2;
   }

   return (\@status, \%headers);
}

# Fecha a conexão
# OBS: não é a melhor forma de fechar; certamente não seria 'graceful',
# mas o servidor que se foda!
sub close {
   my $self = shift;

   return 1 unless defined $self->{sock};

   # (shutdown() + close() = exagero ;)
   shutdown ($self->{sock}, 2);
   close $self->{sock};

   return 1;
}

# Verificação bem simples e tosca se o
# parâmetro (string) é domínio ou endereço IP
sub host_is_IP {
   local $_ = shift;
   return /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/;
}

# Retorna a parte da URL referente somente ao servidor (host/porta)
sub host_port {
   my $uri = shift;
   if ($uri) {
      return sprintf ('%s://%s%s', $uri->scheme, $uri->host, $uri->_port ? ':' . $uri->port : '');
   } else {
      return '';
   }
}

# Retorna mensagem de erro gerada pelo recv()
# OBS: uma grande variedade de erros é produzida pelo recv() operando em larga escala...
# Assim, um mero 'return 0' é incapaz de definir corretamente o que está acontecendo!
sub error {
   my $self = shift;
   return defined $self->{error} ? $self->{error} : '*unknown*';
}

1;
