#!/usr/bin/perl
# Page inlining and blogging.
package IkiWiki::Plugin::inline;

use warnings;
use strict;
use IkiWiki 1.00;
use IkiWiki::Render; # for displaytime
use URI;

sub import { #{{{
	hook(type => "getopt", id => "inline", call => \&getopt);
	hook(type => "checkconfig", id => "inline", call => \&checkconfig);
	hook(type => "preprocess", id => "inline", 
		call => \&IkiWiki::preprocess_inline);
	hook(type => "pagetemplate", id => "inline",
		call => \&IkiWiki::pagetemplate_inline);
	# Hook to change to do pinging since it's called late.
	# This ensures each page only pings once and prevents slow
	# pings interrupting page builds.
	hook(type => "change", id => "inline", 
		call => \&IkiWiki::pingurl);
} # }}}

sub getopt () { #{{{
	eval q{use Getopt::Long};
	error($@) if $@;
	Getopt::Long::Configure('pass_through');
	GetOptions(
		"rss!" => \$config{rss},
		"atom!" => \$config{atom},
	);
}

sub checkconfig () { #{{{
	if (($config{rss} || $config{atom}) && ! length $config{url}) {
		error(gettext("Must specify url to wiki with --url when using --rss or --atom"));
	}
	if ($config{rss}) {
		push @{$config{wiki_file_prune_regexps}}, qr/\.rss$/;
	}
	if ($config{atom}) {
		push @{$config{wiki_file_prune_regexps}}, qr/\.atom$/;
	}
} #}}}

# Back to ikiwiki namespace for the rest, this code is very much
# internal to ikiwiki even though it's separated into a plugin.
package IkiWiki;

my %toping;
my %feedlinks;

sub yesno ($) { #{{{
	my $val=shift;
	return (defined $val && lc($val) eq "yes");
} #}}}

sub preprocess_inline (@) { #{{{
	my %params=@_;
	
	if (! exists $params{pages}) {
		return "";
	}
	my $raw=yesno($params{raw});
	my $archive=yesno($params{archive});
	my $rss=($config{rss} && exists $params{rss}) ? yesno($params{rss}) : $config{rss};
	my $atom=($config{atom} && exists $params{atom}) ? yesno($params{atom}) : $config{atom};
	my $quick=exists $params{quick} ? yesno($params{quick}) : 0;
	my $feeds=exists $params{feeds} ? yesno($params{feeds}) : !$quick;
	if (! exists $params{show} && ! $archive) {
		$params{show}=10;
	}
	my $desc;
	if (exists $params{description}) {
		$desc = $params{description} 
	} else {
		$desc = $config{wikiname};
	}
	my $actions=yesno($params{actions});

	my @list;
	foreach my $page (keys %pagesources) {
		next if $page eq $params{page};
		if (pagespec_match($page, $params{pages})) {
			push @list, $page;
		}
	}

	if (exists $params{sort} && $params{sort} eq 'title') {
		@list=sort @list;
	}
	elsif (! exists $params{sort} || $params{sort} eq 'age') {
		@list=sort { $pagectime{$b} <=> $pagectime{$a} } @list;
	}
	else {
		return sprintf(gettext("unknown sort type %s"), $params{sort});
	}

	if (exists $params{skip}) {
		@list=@list[$params{skip} .. scalar @list - 1];
	}
	
	if ($params{show} && @list > $params{show}) {
		@list=@list[0..$params{show} - 1];
	}

	add_depends($params{page}, $params{pages});

	my $rssurl=rsspage(basename($params{page}));
	my $atomurl=atompage(basename($params{page}));
	my $ret="";

	if (exists $params{rootpage} && $config{cgiurl}) {
		# Add a blog post form, with feed buttons.
		my $formtemplate=template("blogpost.tmpl", blind_cache => 1);
		$formtemplate->param(cgiurl => $config{cgiurl});
		$formtemplate->param(rootpage => $params{rootpage});
		$formtemplate->param(rssurl => $rssurl) if $feeds && $rss;
		$formtemplate->param(atomurl => $atomurl) if $feeds && $atom;
		$ret.=$formtemplate->output;
	}
	elsif ($feeds) {
		# Add feed buttons.
		my $linktemplate=template("feedlink.tmpl", blind_cache => 1);
		$linktemplate->param(rssurl => $rssurl) if $rss;
		$linktemplate->param(atomurl => $atomurl) if $atom;
		$ret.=$linktemplate->output;
	}
	
	my $template=template(
		($archive ? "inlinepagetitle.tmpl" : "inlinepage.tmpl"),
		blind_cache => 1,
	) unless $raw;
	
	foreach my $page (@list) {
		my $file = $pagesources{$page};
		my $type = pagetype($file);
		if (! $raw || ($raw && ! defined $type)) {
			unless ($archive && $quick) {
				# Get the content before populating the
				# template, since getting the content uses
				# the same template if inlines are nested.
				my $content=get_inline_content($page, $params{destpage});
				$template->param(content => $content);
			}
			# Don't use htmllink because this way the
			# title is separate and can be overridden by
			# other plugins.
			my $link=bestlink($params{page}, $page);
			$link=htmlpage($link) if defined $type;
			$link=abs2rel($link, dirname($params{destpage}));
			$template->param(pageurl => $link);
			$template->param(title => pagetitle(basename($page)));
			$template->param(ctime => displaytime($pagectime{$page}));

			if ($actions) {
				my $file = $pagesources{$page};
				my $type = pagetype($file);
				if ($config{discussion} &&
				    $page !~ /.*\/discussion$/ &&
				    (length $config{cgiurl} || exists $links{$page."/".gettext("discussion")})) {
					$template->param(have_actions => 1);
					$template->param(discussionlink => htmllink($page, $params{page}, "Discussion", 1, 1));
				}
				if (length $config{cgiurl} && defined $type) {
					$template->param(have_actions => 1);
					$template->param(editurl => cgiurl(do => "edit", page => $page));
				}
			}

			run_hooks(pagetemplate => sub {
				shift->(page => $page, destpage => $params{page},
					template => $template,);
			});

			$ret.=$template->output;
			$template->clear_params;
		}
		else {
			if (defined $type) {
				$ret.="\n".
				      linkify($page, $params{page},
				      preprocess($page, $params{page},
				      filter($page,
				      readfile(srcfile($file)))));
			}
		}
	}
	
	if ($feeds && $rss) {
		will_render($params{page}, rsspage($params{page}));
		writefile(rsspage($params{page}), $config{destdir},
			genfeed("rss", $rssurl, $desc, $params{page}, @list));
		$toping{$params{page}}=1 unless $config{rebuild};
		$feedlinks{$params{destpage}}=qq{<link rel="alternate" type="application/rss+xml" title="RSS" href="$rssurl" />};
	}
	if ($feeds && $atom) {
		will_render($params{page}, atompage($params{page}));
		writefile(atompage($params{page}), $config{destdir},
			genfeed("atom", $atomurl, $desc, $params{page}, @list));
		$toping{$params{page}}=1 unless $config{rebuild};
		$feedlinks{$params{destpage}}=qq{<link rel="alternate" type="application/atom+xml" title="Atom" href="$atomurl" />};
	}
	
	return $ret;
} #}}}

sub pagetemplate_inline (@) { #{{{
	my %params=@_;
	my $page=$params{page};
	my $template=$params{template};

	$template->param(feedlinks => $feedlinks{$page})
		if exists $feedlinks{$page} && $template->query(name => "feedlinks");
} #}}}

sub get_inline_content ($$) { #{{{
	my $page=shift;
	my $destpage=shift;
	
	my $file=$pagesources{$page};
	my $type=pagetype($file);
	if (defined $type) {
		return htmlize($page, $type,
		       linkify($page, $destpage,
		       preprocess($page, $destpage,
		       filter($page,
		       readfile(srcfile($file))))));
	}
	else {
		return "";
	}
} #}}}

sub date_822 ($) { #{{{
	my $time=shift;

	eval q{use POSIX};
	error($@) if $@;
	my $lc_time= POSIX::setlocale(&POSIX::LC_TIME);
	POSIX::setlocale(&POSIX::LC_TIME, "C");
	my $ret=POSIX::strftime("%a, %d %b %Y %H:%M:%S %z", localtime($time));
	POSIX::setlocale(&POSIX::LC_TIME, $lc_time);
	return $ret;
} #}}}

sub date_3339 ($) { #{{{
	my $time=shift;

	eval q{use POSIX};
	error($@) if $@;
	my $lc_time= POSIX::setlocale(&POSIX::LC_TIME);
	POSIX::setlocale(&POSIX::LC_TIME, "C");
	my $ret=POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", localtime($time));
	POSIX::setlocale(&POSIX::LC_TIME, $lc_time);
	return $ret;
} #}}}

sub absolute_urls ($$) { #{{{
	# sucky sub because rss sucks
	my $content=shift;
	my $baseurl=shift;

	my $url=$baseurl;
	$url=~s/[^\/]+$//;
	
	$content=~s/(<a(?:\s+(?:class|id)="?\w+"?)?)\s+href="(#[^"]+)"/$1 href="$baseurl$2"/ig;
	$content=~s/(<a(?:\s+(?:class|id)="?\w+"?)?)\s+href="(?!\w+:\/\/)([^"]+)"/$1 href="$url$2"/ig;
	$content=~s/(<img(?:\s+(?:class|id)="?\w+"?)?)\s+src="(?!\w+:\/\/)([^"]+)"/$1 src="$url$2"/ig;
	return $content;
} #}}}

sub rsspage ($) { #{{{
	my $page=shift;

	return $page.".rss";
} #}}}

sub atompage ($) { #{{{
	my $page=shift;

	return $page.".atom";
} #}}}

sub genfeed ($$$$@) { #{{{
	my $feedtype=shift;
	my $feedurl=shift;
	my $feeddesc=shift;
	my $page=shift;
	my @pages=@_;
	
	my $url=URI->new(encode_utf8($config{url}."/".htmlpage($page)));
	
	my $itemtemplate=template($feedtype."item.tmpl", blind_cache => 1);
	my $content="";
	my $lasttime = 0;
	foreach my $p (@pages) {
		my $u=URI->new(encode_utf8($config{url}."/".htmlpage($p)));
		
		my $pcontent = absolute_urls(get_inline_content($p, $page), $url);

		$itemtemplate->param(
			title => pagetitle(basename($p), 1),
			url => $u,
			permalink => $u,
			date_822 => date_822($pagectime{$p}),
			date_3339 => date_3339($pagectime{$p}),
		);

		if ($itemtemplate->query(name => "enclosure")) {
			my $file=$pagesources{$p};
			my $type=pagetype($file);
			if (defined $type) {
				$itemtemplate->param(content => $pcontent);
			}
			else {
				my ($a, $b, $c, $d, $e, $f, $g, $size) = stat(srcfile($file));
				my $mime="unknown";
				eval q{use File::MimeInfo};
				if (! $@) {
					$mime = mimetype($file);
				}
				$itemtemplate->param(
					enclosure => $u,
					type => $mime,
					length => $size,
				);
			}
		}
		else {
			$itemtemplate->param(content => $pcontent);
		}

		run_hooks(pagetemplate => sub {
			shift->(page => $p, destpage => $page,
				template => $itemtemplate);
		});

		$content.=$itemtemplate->output;
		$itemtemplate->clear_params;

		$lasttime = $pagectime{$p} if $pagectime{$p} > $lasttime;
	}

	my $template=template($feedtype."page.tmpl", blind_cache => 1);
	$template->param(
		title => $page ne "index" ? pagetitle($page, 1) : $config{wikiname},
		wikiname => $config{wikiname},
		pageurl => $url,
		content => $content,
		feeddesc => $feeddesc,
		feeddate => date_3339($lasttime),
		feedurl => $feedurl,
		version => $IkiWiki::version,
	);
	run_hooks(pagetemplate => sub {
		shift->(page => $page, destpage => $page,
			template => $template);
	});
	
	return $template->output;
} #}}}

sub pingurl (@) { #{{{
	return unless @{$config{pingurl}} && %toping;

	eval q{require RPC::XML::Client};
	if ($@) {
		debug(gettext("RPC::XML::Client not found, not pinging"));
		return;
	}

	# daemonize here so slow pings don't slow down wiki updates
	defined(my $pid = fork) or error("Can't fork: $!");
	return if $pid;
	chdir '/';
	eval q{use POSIX 'setsid'};
	setsid() or error("Can't start a new session: $!");
	open STDIN, '/dev/null';
	open STDOUT, '>/dev/null';
	open STDERR, '>&STDOUT' or error("Can't dup stdout: $!");

	# Don't need to keep a lock on the wiki as a daemon.
	IkiWiki::unlockwiki();

	foreach my $page (keys %toping) {
		my $title=pagetitle(basename($page), 0);
		my $url="$config{url}/".htmlpage($page);
		foreach my $pingurl (@{$config{pingurl}}) {
			debug("Pinging $pingurl for $page");
			eval {
				my $client = RPC::XML::Client->new($pingurl);
				my $req = RPC::XML::request->new('weblogUpdates.ping',
					$title, $url);
				my $res = $client->send_request($req);
				if (! ref $res) {
					debug("Did not receive response to ping");
				}
				my $r=$res->value;
				if (! exists $r->{flerror} || $r->{flerror}) {
					debug("Ping rejected: ".(exists $r->{message} ? $r->{message} : "[unknown reason]"));
				}
			};
			if ($@) {
				debug "Ping failed: $@";
			}
		}
	}

	exit 0; # daemon done
} #}}}

1
