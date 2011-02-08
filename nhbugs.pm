package NHBugsDB;

use strict;
use warnings;

use diagnostics;  # For development


# Set us up the bomb
sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}

sub init {
    my $self = shift;
    my $dbfile = shift || $self->{'dbfile'};
    my $bugpage = shift || $self->{'bugpage'};

    $self->{'dbfile'} = $dbfile if (!$self->{'dbfile'});
    $self->{'bugpage'} = $bugpage if (!$self->{'bugpage'});

    $self->cache_read();
}


sub cache_read {
    my $self = shift;
    open(CACHEFILE,$self->{'dbfile'}) || return;
    while (<CACHEFILE>) {
	my $line = $_;
	$line =~ s/\n+$//;
	my @dat = split('\|', $line);
	$self->{'db'}{$dat[0]}{'state'} = $dat[1];
	$self->{'db'}{$dat[0]}{'text'} = $dat[2];
    }
    close(CACHEFILE);
}

sub cache_write {
    my $self = shift;
    my $line;
    open(CACHEFILE,'>'.$self->{'dbfile'}) || return;
    while (my ($bug) = each %{$self->{'db'}}) {
	my $state = $self->{'db'}{$bug}{'state'};
	my $text = $self->{'db'}{$bug}{'text'};
	print CACHEFILE "$bug|$state|$text\n";
    }
    close(CACHEFILE);
}

sub update_buglist {
    my $self = shift;
    my @bugfile = `/usr/bin/wget --timeout=20 --quiet -O - $self->{'bugpage'}`;

    my $curline;
    my @bugslist;

    my @matching_bugs;
    my @new_bugs;

    my $retstr;

    my $n_bugs = 0;

    for ($curline = 0; $curline < @bugfile; ++$curline) {
	if ($bugfile[$curline] =~ m/<td><a name=.....-.*.>....-.*<\/a>/i) {

	    my ($bugl_name) = $bugfile[$curline] =~ /<td><a name=.....-.*.>(....-.*)<\/a>/;
	    my ($bugl_status) = $bugfile[++$curline] =~ /<td><a href=.*>(.*)<\/a>/;
	    if ($bugl_status =~ /^Fixed/) {
		$bugl_status = "NextVersion";
	    }
	    my ($bugl_info) = $bugfile[++$curline] =~ /<td>(.*)/;
	    if (!($bugfile[++$curline] =~ /^[ \t]*$/)) {
		$bugl_info = $bugl_info . " " . $bugfile[$curline];
	    }

	    $bugl_info =~ tr/\n/ /;

	    if (exists $self->{'db'}{$bugl_name}{'state'}) {
		if ($self->{'db'}{$bugl_name}{'state'} ne $bugl_status) {
		    push(@matching_bugs, "$bugl_name changed to $bugl_status.");
		    $self->{'db'}{$bugl_name}{'state'} = $bugl_status;
		}
	    } else {
		push(@new_bugs, "$bugl_name ($bugl_status): $bugl_info");
		$self->{'db'}{$bugl_name}{'state'} = $bugl_status;
		$self->{'db'}{$bugl_name}{'text'} = $bugl_info;
	    }
	    $n_bugs++;
	}
    }


    my $nnewb = @new_bugs;
    if ($nnewb > 0) {
	$retstr = "$nnewb new bug".($nnewb > 1 ? "s" : "").", total of $n_bugs";
	if ($nnewb < 6) {
	    $retstr = $retstr .":\n". join("\n", @new_bugs);
	} else {
	    $retstr = $retstr . "; See $self->{'bugpage'}";
	}
    }

    $retstr = $retstr ."\n". join(' ', @matching_bugs) if (@matching_bugs);

    return $retstr;
}

sub search_bugs {
    my $self = shift;
    my $bugid = shift;

    my $retstr;

    if ($bugid) {

	my @matchbugs = grep { $_ =~ /^$bugid$/i } keys %{$self->{'db'}};

	if ($#matchbugs < 0) {
	    @matchbugs = grep { $_ =~ /$bugid$/i || $self->{'db'}{$_}->{'state'} =~ /$bugid$/i } keys %{$self->{'db'}};
	}
	if ($#matchbugs < 0) {
	    @matchbugs = grep { $_ =~ /^$bugid/i } keys %{$self->{'db'}};
	}

	if ($#matchbugs < 0) {
	    @matchbugs = grep { $_ =~ /$bugid/i ||
				    $self->{'db'}{$_}{'state'} =~ /$bugid/i ||
				    $self->{'db'}{$_}{'text'} =~ /$bugid/i } keys %{$self->{'db'}};
	}

	if ($#matchbugs < 0) {
	    $retstr = "No matching bugs on the list.";
	} elsif ($#matchbugs == 0) {
	    my $bugstate = $self->{'db'}{$matchbugs[0]}{'state'};
	    my $bugtext = $self->{'db'}{$matchbugs[0]}{'text'};
	    $retstr = "$matchbugs[0], $bugstate: $bugtext";
	} else {
	    my $nmatching = @matchbugs;

	    if ($nmatching < 7) {
		$retstr = "Matching bugs: " . join("  ", @matchbugs);
	    } else {
		$retstr = "$nmatching bugs match \"$bugid\".";
	    }
	}
    } else {
	my $nbugs = 0;
	$nbugs = keys %{$self->{'db'}} if (defined $self->{'db'});

	if ($nbugs > 0) {
	    $retstr = "$nbugs bugs on the buglist at $self->{'bugpage'}";
	} else {
	    $retstr = "Looks like I couldn't get the buglist at $self->{'bugpage'}";
	}
    }
    return $retstr;
}

1;

__END__
