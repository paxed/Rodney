package RedditRSS;

use strict;
use warnings;
use diagnostics;

use HTTP::Date;

sub new {
    my $class = shift;
    my %args = @_;
    return bless \%args, $class;
}

sub init {
    my $self = shift;
    my $rss_url = shift || $self->{'rss_url'};
    my $cachedir = shift || $self->{'cachedir'};

    $self->{'cachefile'} = $rss_url;
    $self->{'cachefile'} =~ s/^http:\/\///;
    $self->{'cachefile'} =~ tr/\//./;

    $self->{'cachedir'} = $cachedir if (!$self->{'cachedir'});
    $self->{'cachedir'} = '.' if (!$self->{'cachedir'});
    $self->{'cachedir'} .= '/' if (!($self->{'cachedir'} =~ m/\/$/));
    $self->{'rss_url'} = $rss_url if (!$self->{'rss_url'});
    $self->{'cachedate'} = 0;

    $self->cache_read();
}

sub cache_read {
    my $self = shift;
    open(CACHEFILE,$self->{'cachedir'}.$self->{'cachefile'}) || return;
    while (<CACHEFILE>) {
	my $line = $_;
	$line =~ s/\n+$//;
	$self->{'cachedate'} = scalar($line);
    }
    close(CACHEFILE);
}

sub cache_write {
    my $self = shift;
    my $line = $self->{'cachedate'};
    open(CACHEFILE,'>'.$self->{'cachedir'}.$self->{'cachefile'}) || return;
    print CACHEFILE "$line\n";
    close(CACHEFILE);
}

sub parse_reddit_rss_itempart {
    my ($part, $data, $itemref) = @_;

    if ($data =~ m/<\Q$part\E>(.+?)<\/\Q$part\E>/) {
	my $title = $1;
	$data =~ s/<\Q$part\E>.+?<\/\Q$part\E>//;
	$itemref->{$part} = $title;
    }
    return $data;
}


sub parse_reddit_rss {
    my $data = shift;

    my @itemlist = ();

    while ($data =~ m/<item>(.+?)<\/item>/) {
	my $itemdata = $1;
	my %item = ();

	$itemdata = parse_reddit_rss_itempart('title', $itemdata, \%item);
	$itemdata = parse_reddit_rss_itempart('link', $itemdata, \%item);
	$itemdata = parse_reddit_rss_itempart('pubDate', $itemdata, \%item);
	$itemdata = parse_reddit_rss_itempart('description', $itemdata, \%item);

	push(@itemlist, \%item);

	$data =~ s/<item>.+?<\/item>//;
    }

    return @itemlist;
}

sub update_rss {
    my $self = shift;
    my @bugfile = `/usr/bin/wget --timeout=20 --quiet -O - $self->{'rss_url'}`;

    my $rssdata = join('', @bugfile);

    my @items = parse_reddit_rss($rssdata);
    my $nitems = scalar(@items);

    my $retstr;

    return $retstr if ($nitems < 1);

    my $i;

    for ($i = 0; $i < $nitems; $i++) {
	if (scalar(str2time($items[$i]->{pubDate})) > $self->{'cachedate'}) {
	    $retstr = 'Reddit: '.$items[$i]->{title}.' ';
	    my $lnk = $items[$i]->{link};
	    my $url = 'http://redd.it/';
	    if ($lnk =~ m/^.+?\/comments\/([a-z0-9]+)\//) {
		$url .= $1;
	    } else {
		$url = $items[$i]->{link};
	    }
	    $retstr .= $url;
	    $self->{'cachedate'} = scalar(str2time($items[$i]->{pubDate}));
	    return $retstr;
	}
    }
    return $retstr;
}


1;

__END__


# slurp the whole file, not each line.
#undef $/;
#my $infile = 'nethack.rss';
#open INFILE, $infile or die "Could not open $infile: $!";
#my $f = <INFILE>;
#close INFILE;
#my @i = parse_reddit_rss($f);
#my $nitems = scalar(@i);
#print $i[0]->{pubDate}."\n";
#my $t = str2time($i[0]->{pubDate});
#print $t."\n";
#print time2str($t)."\n";
