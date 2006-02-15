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


# Vamos comentar esse negócio... Esse vai ser o meu projeto mais bem-comentado!

# 'pragma' que restringe construções inseguras... duh, brincadeira! :P
use strict;


# Obtém a localização do programa
BEGIN { $0 = $^X unless $^X =~ m%(^|[/\\])(perl)|(perl.exe)$%i }
use FindBin qw($RealBin $RealScript);

# Talvez isso ajude a rodar no MacOS? ;)
use File::Spec::Functions;

# Usa os módulos do diretório 'lib' caso eles não estejam presentes no sistema
# ('use libs' sempre prefere os módulos locais aos do sistema!)
BEGIN { push (@INC, catfile ($RealBin, 'lib'), $RealBin) }


# Aqui declaramos os módulos que o código principal estará utilizando:
#use Digest::MD5 qw(md5_base64);
use Fcntl;
use HTML::Entities;
use HTML::HeadParser;
use HTML::LinkExtor;
#use HTTP::Date;
use POSIX qw(getpid nice);
use SDBM_File;
use Time::HiRes qw(gettimeofday tv_interval);
use URI;


# WARN: AnyDBM_File é meio perturbado no UN*X :(
use TieFighter;
use WWW::RobotRules::AnyDBM_File;


# Os módulos internos:
use GetDomain;
use HTTP_Client;
use DNS_Cache;
use Visits;
use Tasklist;

use Configuration;	# mexe nas variáveis internas do HTTP_Cliente do Tasklist!


# E aqui vão as constantes:
use constant NAME	=> ($RealScript =~ /^(.+)\./);	# nome do crawler
							# (obtido do nome do arquivo sem a extensão)
use constant DB_DIR	=> catfile ($RealBin, 'db');	# diretório que guarda os databases
use constant HTML_LINKS	=> qw(a form frame iframe);	# onde podemos encontrar links
use constant MANGLE_URL	=> 1;				# "desmonta" URLs para ampliar a busca
use constant URL_MAXLEN	=> 800;				# URL imensa assim?! algo está errado!
							# WARN: URL tem que caber num registro SDBM!
use constant AUTOFLUSH	=> 10;				# sincroniza databases com os arquivos
use constant PID_FILE	=> catfile ($RealBin, NAME.'.pid');	# PID do processo
use constant LIMITS	=> catfile ($RealBin, 'limits.conf');	# configurações das restrições
use constant SEED	=> catfile ($RealBin, 'seed.conf');	# URLs iniciais
use constant MAIL_LOG	=> catfile (DB_DIR, NAME.'_mail.lst');	# guarda e-mails coletados
use constant KEYWORDS	=> catfile (DB_DIR, 'keywords');	# guarda o texto dos HTMLs processados

use constant MAX_ERR	=> 32;				# limite de erros por host
	our $MAX_DIR	=  0;				# constante "regulável" ;)


# Prioridade mínima para o crawler. Acredito que ele não precise
# de muito processamento... A parte pesada o OS faz por ele :P
nice (-20) if $^O ne 'MSWin32';		# Windows já é podre demais para reduzir a prioridade :P

# Para controle do processo:
open (PID, '>', PID_FILE) or die "can't write PID file: $!\n";
print PID getpid();
close PID;

# Cria o diretório onde guardamos os databases
mkdir DB_DIR, 0700;
mkdir KEYWORDS, 0700;


# Criamos as instâncias encapsuladas:
# (as referências são globais)
our $config	= new Configuration (LIMITS);				# restrições
our $dns	= new DNS_Cache (catfile (DB_DIR, NAME.'_dns'));	# cache de DNS já resolvidos
our $visits	= new Visits (catfile (DB_DIR, NAME.'_visit'));		# database de páginas visitadas
our $urls	= new Tasklist ($visits, catfile (DB_DIR, NAME.'_task'));	# tarefas: páginas para visitar


# OBS: sim, Tasklist utiliza Visits internamente...
# E, por sinal, as informações dos dois são redundantes. Por que não
# combinar os dois? Well... A lógica do Tasklist é símples
# (e, consequentemente, segura) demais para tentar implementá-lo via MySQL.
# Já no Visits, o SDBM provavelmente não dará conta, então será mais
# fácil re-implementá-lo separadamente.


# Longe de ser a melhor forma de fazer isso, mas...
# OBS: no caso de um "resume", vamos tentar adicionar o "seed" na tasklist de qualquer jeito...
load_conf (SEED, sub {
   my $uri = new URI (shift);
   $urls->enqueue (host_port ($uri) . '/robots.txt', $uri->canonical);
});


# Para processar 'robots.txt'
# (outra referência global)
our $robots = new WWW::RobotRules::AnyDBM_File (NAME, catfile (DB_DIR, NAME.'_robots'));


# Contadores de acesso aos diretórios (evita "flood")
our $dir_db = _tie (catfile (DB_DIR, NAME.'_dir'));


# Contadores de erros de acesso
our $blacklist = _tie (catfile (DB_DIR, NAME.'_blacklist'));


# Marca o início do processo
our $started = time;


# %probes conterá a lista com todos os clientes HTTP criados ('probes').
# Por que HASH e não ARRAY? É mais fácil remover clientes que terminaram
# do HASH!
my %probes = ();


# Proteção contra sinais inesperados:
foreach my $sig (keys %SIG) {
   $SIG{$sig} = 'IGNORE';
}

# Flush periodico no disco
$SIG{ALRM} = sub {
   flush ();

   # Reprograma o ALRM
   alarm AUTOFLUSH;
};
alarm AUTOFLUSH;

# Handler para 'reload' das configurações/reset de contadores
$SIG{HUP} = sub {
   # Recarrega as configurações
   $config->reload;
};

# Handler para parada forçada do crawler
my $abort = 0;
$SIG{INT} = sub {
   print "\n########## ABORTING ##########\n\n";

   # Duplo Ctrl-C: parada forçada!
   clean_exit (1) if $abort++;

   flush ();
};

# Sistema sendo desligado?
$SIG{TERM} = sub {
   print "\n########## EXITING! ##########\n\n";
   clean_exit (2);
};


# Marcadores da performance
my $last_recv = $HTTP_Client::recv;
my $last_time = [gettimeofday];


# Ele, o loop principal!
do {
   # Array para probes que bateram as botas.
   # Primeiro, agendamos, e depois, apagamos...
   # Seria insensato apagar coisas do HASH enquanto lemos ele!
   my @to_delete = ();

   # Percorre todos os probes ativos
   # (É possível que não tenhamos nenhum; mas de qualquer forma,
   #  percorremos eles por que uns probes podem criar outros!)
   while (my ($probe_str, $probe) = each %probes) {
      my $mark_for_deletion = 0;	# flag indicando que o probe será desativado
      my $error = 0;			# flag indicando que ocorreu um erro

      # Verifica os eventos dos probes:
      if ($probe->timed_out) {
         # Servidor não responde
         printf STDERR "Timed out while fetching:\n%s\n\n", $probe->URI->canonical;
         ++$mark_for_deletion;
         ++$error;
      } elsif ($probe->has_finished) {
         # HTTP request completo, sem erros

         # Talvez o servidor retornou apenas um link?
         if (my $redir = $probe->header ('Location')) {
            # Agendar o link... Reutilizar o probe não me parece procedimento seguro!
            if ($redir =~ m%^/%) {
               # Malditos redirecionadores relativos :P
               $redir = host_port ($probe->URI) . $redir;
            }

            $urls->enqueue ($redir);
         } else {
            # O servidor retornou conteúdo completo!

            # Imprime indicadores de progresso
            # WARN: a porcentagem indica a posição relativa no tasklist!

            my $xfer = $HTTP_Client::recv - $last_recv;
            my $period = tv_interval ($last_time);
            $last_recv = $HTTP_Client::recv;
            $last_time = [gettimeofday];

            printf "progress: %8s downloaded: %-10s speed: %10s/s size: %10s\n%s\n",
               $urls->progress,
               human_readable ($HTTP_Client::recv),
               human_readable ($period ? ($xfer / $period) : 0),
               human_readable ($probe->size),
               $probe->URI->canonical;

            if ($probe->is_robots) {
               # Processa 'robots.txt'
               my $content = $probe->content;

               unless ($content =~ m%^\s*<%s) {
                  # Morra, maldito!!!
                  {
                     local $^W = 0;	# tira o efeito do "-w" da 1-a linha do source :P
                     $robots->parse ($probe->URI->canonical, $content);
                  }

                  print "*** ROBOTS.TXT (OK) ***\n\n";
               } else {
                  print "*** ROBOTS.TXT (looks like HTML?) ***\n\n";
               }
            } else {
               # Processa o <HEAD> do HTML...
               # No momento, só utilizamos o título da página; mas futuramente,
               # podemos aproveitar os keywords...
               # TODO: será que é possível integrar isso ao extrator de links?
               my $head = new HTML::HeadParser;

               # Malditos módulos malfeitos que ficam reclamando de HTML capenga >%E~
               {
                  local $^W = 0;	# tira o efeito do "-w" da 1-a linha do source :P
                  $head->parse ($probe->content);
               }

               my $title = $head->header ('Title');
               $title = '' unless defined $title;

               # Registra as informações relevantes no database
               # WARN: a interação com o database é... hummmm, curiosa :P
               # Portanto é absolutamente necessário mexer no 'Visits.pm' se mexer aqui!!!
               $visits->record ($probe->URI->canonical,
               {
			#checksum	=> md5_base64 ($probe->content),
			#content_lang	=> $probe->header('Content-Language'),
			#content_length	=> $probe->header('Content-Length'),
			#content_type	=> $probe->header('Content-Type'),
			#date		=> str2time ($probe->header('Date')),
			#expires		=> str2time ($probe->header('Expires')),
			#http_code	=> ${$probe->{status}} [1],
			#http_protocol	=> ${$probe->{status}} [0],
			last_accessed	=> time,
			#last_modified	=> str2time ($probe->header('Last-Modified')),
			received_bytes	=> $probe->{data_length},
			#server		=> $probe->header('Server'),
			#title		=> $title,
               });

               # Processa as informações obtidas (extrai links)
               process (
			$probe,
			$title,
			$head->header ('X-Meta-Description'),
			$head->header ('X-Meta-Keywords'),
               );

               # Depois de processar tudo, imprime o título...
               # Assim, olhando o console, teremos uma idéia visual
               # do quanto tempo o processamento demora ;)
               printf "'%s'\n\n", $title;
            }
         }

         # Esse daqui já era!
         ++$mark_for_deletion;
      } else {
         unless ($probe->is_started) {
            # Antes de iniciar a comunicação HTTP
            if ($probe->got_address) {
               # DNS resolvido! Cria a conexão
               unless ($probe->start) {
                  printf STDERR "Can't start fetching:\n%s\n\n", $probe->URI->canonical;
                  ++$mark_for_deletion;
                  ++$error;
               }
            }
         } else {
            # Depois de iniciar a comunicação HTTP
            if ($probe->exception) {
               # Falha na conexão
               printf STDERR "Exception occoured while fetching:\n%s\n\n", $probe->URI->canonical;
               ++$mark_for_deletion;
               ++$error;
            } elsif ($probe->is_writable) {
               # Já podemos enviar pacotes
               # OBS: só enviamos UM pacote; o do request!
               # WARN: Se ocorre uma falha aqui, descarta o probe inteiro
               unless ($probe->send) {
                  printf STDERR "Aborted send() on:\n%s\n\n", $probe->URI->canonical;
                  ++$mark_for_deletion;
                  ++$error;
               }
            } elsif ($probe->is_readable) {
               # Já podemos receber pacotes (talvez vários)
               # WARN: podem ocorrer MUITAS falhas aqui!
               unless ($probe->recv) {
                  printf STDERR "Aborted recv() on:\n%s\n(Error: %s)\n\n", $probe->URI->canonical, $probe->error;
                  ++$mark_for_deletion;
                  ++$error unless $probe->error =~ /^{WARN}/;	# '{WARN}' marca erros não-críticos, como o 404 :)
               }
            }
         }
      }

      # Incrementa o contador de erros por host
      if ($error) {
         ++${$blacklist} { host_port ($probe->URI) };
      }

      # Probe agendado para exclusão:
      if ($mark_for_deletion) {
         $probe->close;
         push @to_delete, $probe_str;
      }
   }

   # Varre o lixo pra fora ;)
   # (Espero que também limpe a memória, já que elimina
   #  a última referência ao objeto :/)
   delete @probes{@to_delete};

   # Pausa o crawler
   if ($abort and not %probes) {
      flush ();
      print "\n########### PAUSED ###########\n\n";
      print_elapsed ();
      print "\n(press <RETURN> to continue or Ctrl-C to exit)\n";
      my $input = <STDIN>;
      $abort = 0;
   }

   # OK, quantos probes podemos criar agora?
   # WARN: existe o risco de que todos os probes acessem o mesmo
   # servidor, simultaneamente... E se for um servidor meio capenga,
   # não irá responder mais. Há como evitar isso?
   # (se o registro de domínio tiver vários IPs, já aproveitamos isso)
   my $slots = $config->max_probes - (scalar keys %probes);

   # Distribui tarefas aos probes novos
   # OBS: o flag $abort bloqueia a criação de novos probes!
   # Porém continuamos esperando os já existentes terminarem.
   URL: while ((not $abort) and ($slots > 0)) {
      # Pega a próxima URL
      my ($url) = $urls->next;
      last unless defined $url;

      # Só HTTP, no momento...
      next URL unless $url =~ m%^http://%i;

      # Desmonta essa URL
      my $uri = new URI ($url);
      next URL unless $uri;

      # Padroniza esse negócio
      $url = $uri->canonical;

      # Limita os acessos por diretório
      if ($MAX_DIR) {
         my $aux = $url;
         $aux =~ s%\#.*$%%;	# elimina referências internas
         $aux =~ s%\?.*$%%;	# elimina o 'query'

         my ($dir) = ($aux =~ m%^(http://.+)/%i);

         if (defined $dir && (++${$dir_db} {$dir} > $MAX_DIR)) {
            printf STDERR "Exceeding MAX_DIR:\n%s\n\n", $url;
            next;
         }
      }

      # Verifica se 'robots.txt' permite acesso
      # OBS: não é uma solução eficiente filtrar URLs nesse estágio!
      # A razão disso é (contra-)exeplificada assim:
      # 1) crawler entra em um domínio 'a.com' e pega X links para domínio 'b.com'
      # 2) ele agenda o 'b.com/robots.txt' e depois, todos esses links
      #    (nesse estágio, não sabemos o conteúdo desse 'robots.txt'!
      #     pode acontecer que não nos é permitido acessar esses links,
      #     porém eles já foram adicionados!)
      # 3) assim que o crawler pega o 'b.com/robots.txt', ele precisa aplicar as
      #    regras do mesmo *IMEDIATAMENTE*!
      # Assim, o mais seguro é filtrar por 'robots.txt' na hora de criar probes.
      {
         local $^W = 0;	# tira o efeito do "-w" da 1-a linha do source :P
         unless ($robots->allowed ($url)) {
            # Se não podemos acessar, pega mais uma URL do tasklist
            printf STDERR "Rejecting by ROBOTS.TXT:\n%s\n\n", $url;
            next URL;
         }
      }

      # Evita os hosts que retornaram muitos erros
      my $err_count = ${$blacklist} { host_port ($uri) };
      if (defined $err_count and $err_count >= MAX_ERR) {
         printf STDERR "Host is blacklisted (too many errors):\n%s\n\n", $url;
         next URL;
      }

      # Aplica as regras de exclusão das URLs
      # Existe um eval() aqui, portanto é um código ULTRA-LENTO!
      # Por outro lado, as URLs excluidas ocupam espaço no tasklist...
      # A razão pela qual este filtro está no loop principal é:
      # se o crawler se depara com algum server muito hostil, a adição da exclusão
      # no 'limits.conf' deve ser refletida imediatamente!
      foreach my $rule ($config->exclusions) {
         unless (check_url ($uri, $rule)) {
            # Se não podemos acessar, pega mais uma URL do tasklist
            printf STDERR "Rejecting by LIMITS rule:\n%s\n\n", $url;
            next URL;
         }
      }

      # Cria instância do cliente HTTP
      my $probe = new HTTP_Client ($url, NAME, $dns);

      # URL inválida chegou até aqui, quem sabe...
      unless ($probe) {
         printf STDERR "Unable to create a HTTP probe for URL:\n%s\n\n", $url;
         next URL;
      }

      # Inclui o probe recém-criado na lista
      $probes{$probe} = $probe;

      # Slot alocado!
      --$slots;
   }
} while (%probes);	# Continua enquanto há probes ativos


clean_exit (0);


# A parte mais importante do crawler!
# Processa os HTMLs, extrai links e agenda novas visitas.
sub process {
   my ($probe, $title, $desc, $keyw) = @_;

   # já que vamos usar o Content diversas vezes, criamos uma cópia
   my $content = $probe->content;

   # Salvar somente o *texto* do $content em um arquivo
   # WARN: usar regexp para arrancar tudo o que é <...> é cabalmente tosco!!!
   # (mas aparenta funcionar muito bem ;)
   my $txtonly = $content;
   $txtonly =~ s%<\s*script.*?>.*?<\s*/\s*script\s*>%%gis;
   $txtonly =~ s/<.+?>//gs;
   $txtonly =~ s/\s+/\x20/gs;
   $txtonly =~ s/^\s+//;
   $txtonly =~ s/\s+$//;

   # Tira coisas como &atilde; e &nbsp;!
   decode_entities ($txtonly);

   # Deduz o nome do arquivo para gravação
   my $hostname = $probe->URI->host;
   my $dumpto = '';
   if (host_is_IP ($hostname) or (index ($hostname, '.') == -1)) {
      $dumpto = $hostname;
   } else {
      $dumpto = get_domain ($hostname);
   }

   # Se conseguimos um nome...
   if ($dumpto) {
      # Feito para evitar 435739872345 arquivos num mesmo diretório :P
      my @bucket = (KEYWORDS);
      for (my $i = 1; $i <= 2; $i++) {
         push @bucket, substr ($dumpto, 0, $i);
         my $dir = catfile ((@bucket) [0..$i]);
         mkdir ($dir, 0700) unless -d $dir;
      }

      # Berkeley DB é demasiado lerdo para ser abrido e fechado toda hora... :(
      my %kw = ();
      tie (%kw, 'SDBM_File', catfile (@bucket, $dumpto), O_CREAT | O_RDWR, 0600);
      add_keywords (\%kw, \$title,	'#') if $title;
      add_keywords (\%kw, \$desc,	'$') if defined $desc and $desc;
      add_keywords (\%kw, \$keyw,	'%') if defined $keyw and $keyw;
      add_keywords (\%kw, \$txtonly,	'');
      untie %kw;

#      # Grava!
#      # OBS: não há uma razão especial em usar o IO não-bufferizado aqui...
#      # Mas é um pouco mais 'responsável'... Sei lá, talvez seja útil no futuro!
#      sysopen (DATA, catfile (@bucket, $dumpto), O_CREAT | O_WRONLY | O_APPEND) or die "can't store collected data into '$dumpto': $!\n";
#      binmode (DATA, ':utf8');
#      syswrite (DATA, sprintf ("{%s}\n", $probe->URI->canonical));
#      syswrite (DATA, "TITLE=$title\n") if $title;
#      syswrite (DATA, "DESCRIPTION=$desc\n") if defined $desc and $desc;
#      syswrite (DATA, "KEYWORDS=$keyw\n") if defined $keyw and $keyw;
#      syswrite (DATA, "\t" . $txtonly);
#      syswrite (DATA, "\n" x 2);
#      close DATA;
   }

   # Coletânea de todos os links dessa página
   my %urls = ();

   # Usaremos HTML::LinkExtor do LWP (por enquanto)
   my $extor = new HTML::LinkExtor (
      sub {
         my ($tag, %links) = @_;
         return unless grep { $tag eq $_ } HTML_LINKS;
         foreach my $url (values %links) {
            # "Sanity check"
            next unless $url =~ m%^[A-Za-z0-9]+:%;

            # Apaga o que tiver após o '#', excluindo os links internos
            $url =~ s/#.*$//;
            # Elimina as trocentas formas de ordenar o 'directory listing' do Apache
            $url =~ s/\?C=[NMSD];O=[AD]$//;

            # HTML corrompido? Emboscada para crawlers?!
            # OBS: ainda é possíbvel URI->canonical ser maior que URL_MAXLEN!
            # Aqui temos apenas um filtro *PRIMÁRIO*
            next if (length $url) > URL_MAXLEN;

            ++$urls{$url};
         }
      }, $probe->URI->canonical
   );

   # Processa pelo módulo da LWP
   # Malditos módulos malfeitos que ficam reclamando de HTML capenga >%E~
   {
      local $^W = 0;	# tira o efeito do "-w" da 1-a linha do source :P
      $extor->parse ($content);
   }

   # E aqui vão os resultados refinados
   my @urls = ();
   my @mangle = ();

   # Separa apenas os domínios, para dar prefetch dos 'robots.txt'
   my %domains = ();

   # Coleta os e-mails
   my %mail = ();

   # Primeiro passo: obviamente não precisamos re-visitar ESSA página :P
   delete $urls{$probe->URI->canonical};

   # O filtro principal de URLs
   URL: foreach my $url (keys %urls) {
      # Desmonta a URL pelo módulo URI
      my $uri = new URI ($url);
      next URL unless $uri;

      my $scheme = $uri->scheme;
      next URL unless defined $scheme;

      # Evita URLs gigantes a todo custo... Pra não corromper database, entre outras coisas :P
      next if (length $uri->canonical) > URL_MAXLEN;

      # Coletor de e-mails
      if ($scheme eq 'mailto') {
         # Separa strings que se assemelham a um endereço de e-mail
         foreach my $mail (split /[^\w\-\.@]+/, $uri->to) {
            ++$mail{$mail} if $mail =~ /^[a-z0-9]+\.?[\w\.]*@[\w\.]+\.[a-z0-9]+$/i;
         }

         next URL;
      }

      # Ignora tudo que não é HTTP
      next URL unless $scheme eq 'http';

      # Domínio inválido (Net::DNS se recusará a resolver)
      next if $uri->host =~ /^[^\.]{64,}/;

      # Verifica as extensões e evita tudo o que NÃO É HTML
      my $file = ($uri->path_segments) [-1];
      if ($file and $file =~ /.*\.(.+?)$/) {
         my $ext = lc $1;
         $ext =~ s/[^a-z0-9].*$//;

         # Esqueci de algum?
         next URL unless (($ext eq '')
            or ($ext =~ /^[a-z]?html?$/)	# HTML
            or ($ext =~ /^php[0-9]$/)		# PHP
            or ($ext =~ /^aspx?$/)		# ASP
            or ($ext =~ /^plx?$/)		# Perl
            or ($ext =~ /^(cgi|dll|exe|jsp)$/)	# & Cia.
         );
      }

      # Agenda a URL 'normalizada'
      push @urls, $uri->canonical;

      # Amplia a busca "fatiando" a URL e visitando diretórios inferiores e hosts superiores
      push (@mangle, mangle ($uri)) if MANGLE_URL;

      # Guarda o domínio/porta
      ++$domains{ host_port ($uri) };
   }

   # Agenda os 'robots.txt' ANTES dos links para os domínios
   my @robots = ();
   foreach my $domain (keys %domains) {
      push @robots, $domain . '/robots.txt';
   }

   # Põe na fila o que sobrou.
   # O módulo responsável verificará se essas URLs já foram agendadas!
   $urls->enqueue (@robots, @urls, @mangle);

   # Guarda os e-mails coletados
   if (each %mail) {
      open (MAIL, '>>', MAIL_LOG) or die "can't log mails: $!\n";
      # Aonde coletamos esses mails
      printf MAIL "[%s]\n", $probe->URI->canonical;
      foreach my $mail (keys %mail) {
         print MAIL "$mail\n";
      }
      print MAIL "\n";
      close MAIL;
   }

   return 1;
}

# Dá um fim nos acentos... Existe também no CEP.pm!!!
sub normalize {
   local $_ = lc shift;
   tr/\xBA\xAA`´’ÇçÑñÃÕãõÂÊÎÔÛâêîôûÀÈÌÒÙàèìòùÁÉÍÓÚáéíóúÄËÏÖÜäëïöü/oa'''ccnnaoaoaeiouaeiouaeiouaeiouaeiouaeiouaeiouaeiou/;
   return $_;
}

# Database de ocorrência de keywords; individual para cada domínio:
sub add_keywords {
   my ($kw, $str, $prefix) = @_;

   # Define a classe de "não-palavra" (em português brasileiro)
   my $regexp = qr/[^A-Za-z0-9\_\-]+/;

   # Pega as não-não-palavras o_O
   foreach my $keyword (split $regexp, ${$str}) {
      my $clean = normalize ($keyword);
      my $len = length $clean;
      if ($len >= 3 and $len <= 30) {
         $clean = $prefix . $clean;

         # Armazena os contadores pack()ados para simplificar o sort()
         # e tentar reduzir a fragmentação do arquivo do SDBM...
         my $p = ${$kw} {$clean};
         my $n = (defined $p) ? unpack ('N', $p) : 0;
         ${$kw} {$clean} = pack ('N', ++$n);
      }
   }

   return 1;
}

# WARN: Beeeem obscuro... Precisa ser testado melhor; talvez nem valha a pena.
sub mangle {
   my ($uri, $path_only) = @_;

   # Mexe no path da URL... Tipo, para http://sysd.org/a/b/c/d/, desmonta em:
   # http://sysd.org/a/b/c/
   # http://sysd.org/a/b/
   # http://sysd.org/a/
   # http://sysd.org/

   my @mangle_path = ();
   my @path = $uri->path_segments;
   my $start = $#path - 1;
   --$start unless $path[-1];
   for (my $i = $start; $i >= 0; $i--) {
      push @mangle_path, host_port ($uri) . join ('/', @path[0..$i], '');
   }

   # WARN: o que acontece se 'www.sysd.org' e 'sysd.org' apontam para o *MESMO SITE*?!
   # Resposta: baixa tudo de novo! *NORMALMENTE*, 'www.sysd.org' redirecionará para 'sysd.org' :P
   #return @mangle_path;

   # Não mexer no host!
   return @mangle_path if defined $path_only;

   # Mexe no host da URL. Para http://www.xplane.stas.sysd.org/, gera:
   # http://xplane.stas.sysd.org/robots.txt
   # http://xplane.stas.sysd.org/
   # http://stas.sysd.org/robots.txt
   # http://stas.sysd.org/
   # http://sysd.org/robots.txt
   # http://sysd.org/

   # Ooops! Não se aplica a endereços IP!
   return @mangle_path if host_is_IP ($uri->host);

   my @mangle_host = ();
   my @host = split /\./, $uri->host;

   # Muitas vezes www.host.com é idêntico ao host.com!!!
   return @mangle_path if lc $host[0] eq 'www';

   for (my $i = $#host - 1; $i > 0; $i--) {
      my $domain = sprintf 'http://%s/', join ('.', @host[$i..$#host]);
      unshift @mangle_host, $domain;
      unshift @mangle_host, $domain . 'robots.txt';
   }

   return @mangle_path, @mangle_host;
}

# Transforma o número de bytes em KB/MB/GB/TB
sub human_readable {
   my $n = int (shift);
   my @a = qw(KB MB GB TB);
   my $i;
   for ($i = 0; ($i <= $#a) and ($n >= 1024); $i++) {
      $n /= 1024;
   }

   return $i ? sprintf '%0.2f %s', $n, $a[$i - 1] : "$n bytes";
}

# Computa o tempo total gasto e imprime de forma legível
sub print_elapsed {
   my $sec = time - $started;

   my $min = int ($sec / 60);
   $sec %= 60;
   my $hour = int ($min / 60);
   $min %= 60;
   my $day = int ($hour / 24);
   $hour %= 24;

   printf "elapsed: %3d days %02d:%02d:%02d\n", $day, $hour, $min, $sec;

   return;
}

# Sincroniza os arquivos de dados com o disco
sub flush {
   # Atualiza o arquivo .pos
   $urls->save_state;

   # Sincroniza os databases
   _sync ($dir_db);
   _sync ($blacklist);
   _sync ($dns->{'db'});
   _sync ($robots->{'dbm'});
   _sync ($visits->{'db'});

   return 1;
}

# Verifica se dada URL não está na lista das exclusões
sub check_url {
   # As regras do 'limits.conf' acessam $uri!
   my ($uri, $eval) = @_;
   my $flag = 0;
   return not eval "\$flag=($eval)";
}

# Finalização limpa do processo
sub clean_exit {
   my $code = shift;

   # Fecha os databases
   $urls->save_state;

   untie %{$dir_db};
   untie %{$blacklist};
   $dns->close;
   $urls->close;
   $visits->close;

   # Apaga o arquivo com o PID
   unlink PID_FILE;

   # Algumas estatísticas
   print "\n";
   print_elapsed;

   # Até!
   return exit $code;
}
